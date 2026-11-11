// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, IOracle, Id, MarketParams} from "./interfaces/IMorpho.sol";

/// @title WeekendGuard
/// @notice Liquidation protection for Morpho Blue borrowers who use tokenized stocks as collateral.
///         Stocks do not trade on weekends, so Monday's open can gap far below Friday's close and
///         liquidate a position before its owner can react. WeekendGuard lets a borrower pre-authorize
///         a bounded top-up (extra collateral) or partial repayment that any keeper can execute when
///         the position's health factor falls below a chosen trigger. During the weekend window the
///         health factor is evaluated against a stressed price (spot minus an expected gap), so
///         protection kicks in *before* the market reopens.
/// @dev    Non-custodial: funds move straight from the user's wallet into their own Morpho position.
///         The guard never needs Morpho authorization, because Morpho lets anyone supply collateral
///         or repay on behalf of another address. Each user caps per-action size and total budget.
/// @custom:security UNAUDITED. Testnet / grant-demo use only until audited.
contract WeekendGuard is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    enum Mode {
        ADD_COLLATERAL, // pull collateral token from the user, supply it to Morpho
        REPAY // pull loan token from the user, repay Morpho debt
    }

    /// @param active        set by the contract on setConfig, cleared by disable
    /// @param mode          how to restore health
    /// @param triggerHf     protect when HF < triggerHf (1e18 = 1.0). Must be > 1.0
    /// @param targetHf      HF to restore after protection. Must be > triggerHf
    /// @param weekendGapBps simulated price drop applied inside the weekend window (1500 = 15%)
    /// @param keeperFeeBps  reward paid to the caller, on top of the protection amount
    /// @param cooldown      minimum seconds between two protections
    /// @param maxPerAction  max tokens (excluding fee) pulled per protection
    /// @param budgetLeft    total tokens (including fees) the guard may still pull
    struct Config {
        bool active;
        Mode mode;
        uint64 triggerHf;
        uint64 targetHf;
        uint16 weekendGapBps;
        uint16 keeperFeeBps;
        uint32 cooldown;
        uint128 maxPerAction;
        uint128 budgetLeft;
    }

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant ORACLE_PRICE_SCALE = 1e36;
    uint256 public constant MAX_TARGET_HF = 10e18;
    uint256 public constant MAX_GAP_BPS = 5_000; // 50%
    uint256 public constant MAX_KEEPER_FEE_BPS = 100; // 1%

    // Morpho Blue SharesMathLib virtual amounts
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    // Weekend window (UTC): Friday 19:00 -> Monday 14:30.
    // Covers the US close (20:00 UTC in winter, 20:00/21:00 depending on DST is handled
    // conservatively) through the Monday open (13:30/14:30 UTC). Market holidays are NOT covered
    // here; the keeper bot handles them off-chain by calling protect earlier if needed.
    uint256 internal constant FRIDAY_START = 19 hours;
    uint256 internal constant MONDAY_END = 14 hours + 30 minutes;

    // ---------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------

    IMorpho public immutable morpho;

    mapping(address user => mapping(Id id => Config)) public configs;
    mapping(address user => mapping(Id id => uint256)) public lastAction;

    // ---------------------------------------------------------------------
    // Events & errors
    // ---------------------------------------------------------------------

    event ConfigSet(address indexed user, Id indexed id, Config config);
    event Disabled(address indexed user, Id indexed id);
    event Protected(
        address indexed user,
        Id indexed id,
        address indexed keeper,
        Mode mode,
        uint256 amount,
        uint256 fee,
        uint256 hfBefore,
        uint256 hfAfter
    );

    error UnknownMarket();
    error InvalidConfig();
    error NotActive();
    error CooldownActive();
    error PositionHealthy();
    error NothingToDo();
    error BadPrice();

    constructor(IMorpho _morpho) {
        morpho = _morpho;
    }

    // ---------------------------------------------------------------------
    // User actions
    // ---------------------------------------------------------------------

    /// @notice Enable or update protection for the caller's position in market `id`.
    /// @dev    The caller must also `approve` this contract on the collateral token (ADD_COLLATERAL)
    ///         or the loan token (REPAY) for at least `budgetLeft`.
    function setConfig(Id id, Config calldata cfg) external {
        _params(id); // reverts on unknown market
        if (cfg.triggerHf <= WAD) revert InvalidConfig();
        if (cfg.targetHf <= cfg.triggerHf || cfg.targetHf > MAX_TARGET_HF) revert InvalidConfig();
        if (cfg.weekendGapBps > MAX_GAP_BPS) revert InvalidConfig();
        if (cfg.keeperFeeBps > MAX_KEEPER_FEE_BPS) revert InvalidConfig();
        if (cfg.maxPerAction == 0 || cfg.budgetLeft == 0) revert InvalidConfig();

        Config memory c = cfg;
        c.active = true;
        configs[msg.sender][id] = c;
        emit ConfigSet(msg.sender, id, c);
    }

    function disable(Id id) external {
        configs[msg.sender][id].active = false;
        emit Disabled(msg.sender, id);
    }

    // ---------------------------------------------------------------------
    // Keeper action
    // ---------------------------------------------------------------------

    /// @notice Restore the health of `user`'s position if it is below their trigger. Callable by anyone.
    /// @return amount tokens supplied/repaid into Morpho (excluding the keeper fee)
    function protect(address user, Id id) external nonReentrant returns (uint256 amount) {
        Config storage cfg = configs[user][id];
        if (!cfg.active) revert NotActive();
        if (block.timestamp < lastAction[user][id] + cfg.cooldown) revert CooldownActive();

        MarketParams memory mp = _params(id);
        morpho.accrueInterest(mp);

        uint256 gap = isWeekendWindow(block.timestamp) ? cfg.weekendGapBps : 0;
        uint256 hfBefore = _healthFactor(id, user, mp, gap);
        if (hfBefore >= cfg.triggerHf) revert PositionHealthy();

        bool fullRepay;
        (amount, fullRepay) = _requiredAmount(id, user, mp, cfg, gap);
        uint256 fee;
        (amount, fee, fullRepay) = _applyLimits(cfg, amount, fullRepay);
        if (amount == 0) revert NothingToDo();

        // effects
        cfg.budgetLeft -= uint128(amount + fee);
        lastAction[user][id] = block.timestamp;

        // interactions
        _execute(user, id, mp, cfg.mode, amount, fee, fullRepay);

        uint256 hfAfter = _healthFactor(id, user, mp, gap);
        emit Protected(user, id, msg.sender, cfg.mode, amount, fee, hfBefore, hfAfter);
    }

    // ---------------------------------------------------------------------
    // Views (for keepers & frontend)
    // ---------------------------------------------------------------------

    /// @notice Health factor of `user` in market `id`, using the stressed price if inside the
    ///         weekend window. Uses stored market totals (interest not accrued), so it can be very
    ///         slightly optimistic; `protect` accrues first.
    function healthFactor(address user, Id id) external view returns (uint256) {
        Config memory cfg = configs[user][id];
        uint256 gap = isWeekendWindow(block.timestamp) ? cfg.weekendGapBps : 0;
        return _healthFactor(id, user, _params(id), gap);
    }

    /// @notice Off-chain helper for keepers: would `protect` do something right now, and how much?
    function check(address user, Id id) external view returns (bool canProtect, uint256 amount, uint256 hf) {
        Config memory cfg = configs[user][id];
        MarketParams memory mp = _params(id);
        uint256 gap = isWeekendWindow(block.timestamp) ? cfg.weekendGapBps : 0;
        hf = _healthFactor(id, user, mp, gap);
        if (!cfg.active || hf >= cfg.triggerHf) return (false, 0, hf);
        if (block.timestamp < lastAction[user][id] + cfg.cooldown) return (false, 0, hf);
        bool fullRepay;
        (amount, fullRepay) = _requiredAmount(id, user, mp, cfg, gap);
        (amount,,) = _applyLimits(cfg, amount, fullRepay);
        canProtect = amount > 0;
    }

    /// @notice True between Friday 19:00 UTC and Monday 14:30 UTC.
    function isWeekendWindow(uint256 ts) public pure returns (bool) {
        uint256 dow = ((ts / 1 days) + 4) % 7; // 0 = Sunday ... 6 = Saturday (1970-01-01 was a Thursday)
        uint256 sod = ts % 1 days;
        if (dow == 6 || dow == 0) return true;
        if (dow == 5) return sod >= FRIDAY_START;
        if (dow == 1) return sod < MONDAY_END;
        return false;
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _params(Id id) internal view returns (MarketParams memory mp) {
        (address loan, address coll, address oracle, address irm, uint256 lltv) = morpho.idToMarketParams(id);
        if (loan == address(0)) revert UnknownMarket();
        mp = MarketParams(loan, coll, oracle, irm, lltv);
    }

    function _state(Id id, address user, MarketParams memory mp, uint256 gapBps)
        internal
        view
        returns (uint256 collateral, uint256 debt, uint256 price)
    {
        (, uint128 borrowShares, uint128 coll) = morpho.position(id, user);
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(id);
        collateral = coll;
        debt = Math.mulDiv(
            borrowShares,
            uint256(totalBorrowAssets) + VIRTUAL_ASSETS,
            uint256(totalBorrowShares) + VIRTUAL_SHARES,
            Math.Rounding.Ceil
        );
        price = Math.mulDiv(IOracle(mp.oracle).price(), BPS - gapBps, BPS);
    }

    /// @dev HF = collateralValue * lltv / debt, 1e18-scaled. type(uint256).max when there is no debt.
    function _healthFactor(Id id, address user, MarketParams memory mp, uint256 gapBps)
        internal
        view
        returns (uint256)
    {
        (uint256 collateral, uint256 debt, uint256 price) = _state(id, user, mp, gapBps);
        if (debt == 0) return type(uint256).max;
        uint256 value = Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE);
        return Math.mulDiv(value, mp.lltv, debt);
    }

    /// @dev Amount needed to bring HF back to targetHf (before caps).
    function _requiredAmount(Id id, address user, MarketParams memory mp, Config memory cfg, uint256 gapBps)
        internal
        view
        returns (uint256 amount, bool fullRepay)
    {
        (uint256 collateral, uint256 debt, uint256 price) = _state(id, user, mp, gapBps);
        if (debt == 0) return (0, false);

        if (cfg.mode == Mode.ADD_COLLATERAL) {
            if (price == 0) revert BadPrice();
            // needed = targetHf * debt / lltv / price   (in collateral units)
            uint256 neededValue = Math.mulDiv(debt, cfg.targetHf, mp.lltv, Math.Rounding.Ceil);
            uint256 needed = Math.mulDiv(neededValue, ORACLE_PRICE_SCALE, price, Math.Rounding.Ceil);
            amount = needed > collateral ? needed - collateral : 0;
        } else {
            // maxDebt = collateralValue * lltv / targetHf   (in loan units)
            uint256 value = Math.mulDiv(collateral, price, ORACLE_PRICE_SCALE);
            uint256 maxDebt = Math.mulDiv(value, mp.lltv, cfg.targetHf);
            if (maxDebt >= debt) return (0, false);
            amount = debt - maxDebt;
            if (maxDebt == 0) fullRepay = true; // repay everything by shares to avoid dust
        }
    }

    /// @dev Applies maxPerAction and budget caps and computes the keeper fee.
    function _applyLimits(Config memory cfg, uint256 amount, bool fullRepay)
        internal
        pure
        returns (uint256, uint256 fee, bool)
    {
        if (amount > cfg.maxPerAction) {
            amount = cfg.maxPerAction;
            fullRepay = false;
        }
        fee = amount * cfg.keeperFeeBps / BPS;
        if (amount + fee > cfg.budgetLeft) {
            amount = uint256(cfg.budgetLeft) * BPS / (BPS + cfg.keeperFeeBps);
            fee = amount * cfg.keeperFeeBps / BPS;
            fullRepay = false;
        }
        return (amount, fee, fullRepay);
    }

    function _execute(
        address user,
        Id id,
        MarketParams memory mp,
        Mode mode,
        uint256 amount,
        uint256 fee,
        bool fullRepay
    ) internal {
        IERC20 token = IERC20(mode == Mode.ADD_COLLATERAL ? mp.collateralToken : mp.loanToken);

        token.safeTransferFrom(user, address(this), amount + fee);
        if (fee > 0) token.safeTransfer(msg.sender, fee);

        token.forceApprove(address(morpho), amount);
        if (mode == Mode.ADD_COLLATERAL) {
            morpho.supplyCollateral(mp, amount, user, "");
        } else if (fullRepay) {
            (, uint128 borrowShares,) = morpho.position(id, user);
            morpho.repay(mp, 0, borrowShares, user, "");
        } else {
            morpho.repay(mp, amount, 0, user, "");
        }
        token.forceApprove(address(morpho), 0);
    }
}
