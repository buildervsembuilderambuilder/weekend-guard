// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IMorpho, IOracle, Id, MarketParams} from "../../src/interfaces/IMorpho.sol";

contract MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amt) external {
        _mint(to, amt);
    }
}

contract MockOracle is IOracle {
    uint256 public override price;

    function setPrice(uint256 p) external {
        price = p;
    }
}

/// @dev Tiny Morpho Blue stand-in: same share math, no interest, no liquidations.
contract MockMorpho is IMorpho {
    uint256 internal constant VIRTUAL_SHARES = 1e6;
    uint256 internal constant VIRTUAL_ASSETS = 1;

    struct Pos {
        uint128 borrowShares;
        uint128 collateral;
    }

    struct Mkt {
        uint128 totalBorrowAssets;
        uint128 totalBorrowShares;
    }

    mapping(Id => MarketParams) internal _params;
    mapping(Id => Mkt) internal _markets;
    mapping(Id => mapping(address => Pos)) internal _pos;

    function createMarket(MarketParams memory mp) external returns (Id id) {
        id = Id.wrap(keccak256(abi.encode(mp)));
        _params[id] = mp;
    }

    /// @dev Test helper: give `user` a position with `collateral` and `debt` (assets).
    function setPosition(Id id, address user, uint128 collateral, uint128 debt) external {
        Mkt storage m = _markets[id];
        uint256 shares = Math.mulDiv(debt, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS);
        m.totalBorrowAssets += debt;
        m.totalBorrowShares += uint128(shares);
        _pos[id][user] = Pos(uint128(shares), collateral);
    }

    function position(Id id, address user) external view returns (uint256, uint128, uint128) {
        Pos memory p = _pos[id][user];
        return (0, p.borrowShares, p.collateral);
    }

    function market(Id id) external view returns (uint128, uint128, uint128, uint128, uint128, uint128) {
        Mkt memory m = _markets[id];
        return (0, 0, m.totalBorrowAssets, m.totalBorrowShares, 0, 0);
    }

    function idToMarketParams(Id id) external view returns (address, address, address, address, uint256) {
        MarketParams memory mp = _params[id];
        return (mp.loanToken, mp.collateralToken, mp.oracle, mp.irm, mp.lltv);
    }

    function accrueInterest(MarketParams memory) external {}

    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes memory) external {
        Id id = Id.wrap(keccak256(abi.encode(mp)));
        _pos[id][onBehalf].collateral += uint128(assets);
        IERC20(mp.collateralToken).transferFrom(msg.sender, address(this), assets);
    }

    function repay(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes memory)
        external
        returns (uint256, uint256)
    {
        Id id = Id.wrap(keccak256(abi.encode(mp)));
        Mkt storage m = _markets[id];
        if (assets > 0) {
            shares = Math.mulDiv(assets, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS);
        } else {
            assets = Math.mulDiv(shares, uint256(m.totalBorrowAssets) + VIRTUAL_ASSETS, uint256(m.totalBorrowShares) + VIRTUAL_SHARES, Math.Rounding.Ceil);
        }
        _pos[id][onBehalf].borrowShares -= uint128(shares);
        m.totalBorrowShares -= uint128(shares);
        m.totalBorrowAssets = assets > m.totalBorrowAssets ? 0 : m.totalBorrowAssets - uint128(assets);
        IERC20(mp.loanToken).transferFrom(msg.sender, address(this), assets);
        return (assets, shares);
    }
}
