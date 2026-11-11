// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeekendGuard} from "../src/WeekendGuard.sol";
import {Id, MarketParams} from "../src/interfaces/IMorpho.sol";
import {MockERC20, MockOracle, MockMorpho} from "./mocks/Mocks.sol";

contract WeekendGuardTest is Test {
    // Timestamps (UTC)
    uint256 constant WED_NOON = 1794398400; // 2026-11-11 12:00 Wed
    uint256 constant FRI_1800 = 1794592800; // 2026-11-13 18:00 Fri
    uint256 constant FRI_2000 = 1794600000; // 2026-11-13 20:00 Fri
    uint256 constant SAT_NOON = 1794657600; // 2026-11-14 12:00 Sat
    uint256 constant SUN_NOON = 1794744000; // 2026-11-15 12:00 Sun
    uint256 constant MON_1400 = 1794837600; // 2026-11-16 14:00 Mon
    uint256 constant MON_1500 = 1794841200; // 2026-11-16 15:00 Mon

    // Price of 1 stock token (18 dec) in USDG (6 dec), Morpho 1e36 scale: $1 => 1e24
    uint256 constant PRICE_200 = 200e24;
    uint256 constant PRICE_170 = 170e24;
    uint256 constant LLTV = 0.77e18;

    MockMorpho morpho;
    MockOracle oracle;
    MockERC20 stock; // tokenized stock, 18 decimals
    MockERC20 usdg; // stablecoin, 6 decimals
    WeekendGuard guard;
    Id id;

    address user = makeAddr("user");
    address keeper = makeAddr("keeper");

    function setUp() public {
        morpho = new MockMorpho();
        oracle = new MockOracle();
        stock = new MockERC20("Stock Token", "sTSLA", 18);
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        guard = new WeekendGuard(morpho);

        id = morpho.createMarket(
            MarketParams({
                loanToken: address(usdg),
                collateralToken: address(stock),
                oracle: address(oracle),
                irm: address(0),
                lltv: LLTV
            })
        );
        oracle.setPrice(PRICE_200);

        // 10 stock ($2,000) collateral, $1,200 debt => HF = 2000*0.77/1200 = 1.283
        morpho.setPosition(id, user, 10e18, 1200e6);

        stock.mint(user, 100e18);
        usdg.mint(user, 10_000e6);
        vm.startPrank(user);
        stock.approve(address(guard), type(uint256).max);
        usdg.approve(address(guard), type(uint256).max);
        vm.stopPrank();

        vm.warp(WED_NOON);
    }

    // ------------------------------------------------------------------ helpers

    function _cfg(WeekendGuard.Mode mode) internal pure returns (WeekendGuard.Config memory c) {
        c.mode = mode;
        c.triggerHf = 1.15e18;
        c.targetHf = 1.4e18;
        c.weekendGapBps = 1500; // 15% Monday gap assumption
        c.keeperFeeBps = 30; // 0.3%
        c.cooldown = 1 hours;
        if (mode == WeekendGuard.Mode.ADD_COLLATERAL) {
            c.maxPerAction = 50e18;
            c.budgetLeft = 100e18;
        } else {
            c.maxPerAction = 2_000e6;
            c.budgetLeft = 5_000e6;
        }
    }

    function _enable(WeekendGuard.Config memory c) internal {
        vm.prank(user);
        guard.setConfig(id, c);
    }

    function _collateral() internal view returns (uint256 c) {
        (,, uint128 coll) = morpho.position(id, user);
        c = coll;
    }

    // ------------------------------------------------------------------ weekend window

    function test_isWeekendWindow() public view {
        assertFalse(guard.isWeekendWindow(WED_NOON));
        assertFalse(guard.isWeekendWindow(FRI_1800));
        assertTrue(guard.isWeekendWindow(FRI_2000));
        assertTrue(guard.isWeekendWindow(SAT_NOON));
        assertTrue(guard.isWeekendWindow(SUN_NOON));
        assertTrue(guard.isWeekendWindow(MON_1400));
        assertFalse(guard.isWeekendWindow(MON_1500));
    }

    // ------------------------------------------------------------------ core flows

    function test_revertsWhenHealthyOnWeekday() public {
        _enable(_cfg(WeekendGuard.Mode.ADD_COLLATERAL));
        vm.prank(keeper);
        vm.expectRevert(WeekendGuard.PositionHealthy.selector);
        guard.protect(user, id);
    }

    function test_addCollateralAfterPriceDrop() public {
        _enable(_cfg(WeekendGuard.Mode.ADD_COLLATERAL));
        oracle.setPrice(PRICE_170); // HF = 1700*0.77/1200 = 1.091 < 1.15

        vm.prank(keeper);
        uint256 amount = guard.protect(user, id);

        // needed = 1.4 * 1200 / (0.77 * 170) = 12.834 stock => add ~2.834
        assertApproxEqRel(amount, 2.834e18, 1e15);
        assertEq(_collateral(), 10e18 + amount);
        assertEq(stock.balanceOf(keeper), amount * 30 / 10_000);
        assertApproxEqRel(guard.healthFactor(user, id), 1.4e18, 1e15);
        assertGe(guard.healthFactor(user, id), 1.4e18 - 1e12);
    }

    function test_weekendStressTriggersBeforeMondayOpen() public {
        _enable(_cfg(WeekendGuard.Mode.ADD_COLLATERAL));

        // Wednesday, $200: healthy (HF 1.283)
        vm.prank(keeper);
        vm.expectRevert(WeekendGuard.PositionHealthy.selector);
        guard.protect(user, id);

        // Saturday, still $200 spot, but stressed price $170 => HF 1.091 < 1.15
        vm.warp(SAT_NOON);
        vm.prank(keeper);
        uint256 amount = guard.protect(user, id);
        assertGt(amount, 0);
        assertApproxEqRel(guard.healthFactor(user, id), 1.4e18, 1e15);

        // If Monday opens 15% lower, the position is still at the target HF instead of near liquidation
        vm.warp(MON_1500);
        oracle.setPrice(PRICE_170);
        assertApproxEqRel(guard.healthFactor(user, id), 1.4e18, 1e15);
    }

    function test_repayMode() public {
        _enable(_cfg(WeekendGuard.Mode.REPAY));
        oracle.setPrice(PRICE_170);

        uint256 balBefore = usdg.balanceOf(user);
        vm.prank(keeper);
        uint256 amount = guard.protect(user, id);

        // maxDebt = 1700 * 0.77 / 1.4 = 935 => repay 265
        assertApproxEqAbs(amount, 265e6, 1e3);
        assertEq(usdg.balanceOf(keeper), amount * 30 / 10_000);
        assertEq(balBefore - usdg.balanceOf(user), amount + amount * 30 / 10_000);
        assertApproxEqRel(guard.healthFactor(user, id), 1.4e18, 1e15);
    }

    // ------------------------------------------------------------------ limits

    function test_capsAtMaxPerAction() public {
        WeekendGuard.Config memory c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);
        c.maxPerAction = 1e18;
        _enable(c);
        oracle.setPrice(PRICE_170);

        vm.prank(keeper);
        assertEq(guard.protect(user, id), 1e18);
    }

    function test_capsAtBudgetIncludingFee() public {
        WeekendGuard.Config memory c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);
        c.budgetLeft = 1e18;
        _enable(c);
        oracle.setPrice(PRICE_170);

        vm.prank(keeper);
        uint256 amount = guard.protect(user, id);
        assertEq(amount, uint256(1e18) * 10_000 / 10_030);
        (,,,,,,,, uint128 budgetLeft) = guard.configs(user, id);
        assertLe(budgetLeft, 1);
    }

    function test_cooldown() public {
        WeekendGuard.Config memory c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);
        c.maxPerAction = 0.2e18; // small top-ups so the position stays below trigger (10.2 => HF 1.113)
        _enable(c);
        oracle.setPrice(PRICE_170);

        vm.prank(keeper);
        guard.protect(user, id);

        vm.prank(keeper);
        vm.expectRevert(WeekendGuard.CooldownActive.selector);
        guard.protect(user, id);

        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        assertEq(guard.protect(user, id), 0.2e18);
    }

    function test_checkMatchesProtect() public {
        _enable(_cfg(WeekendGuard.Mode.ADD_COLLATERAL));
        oracle.setPrice(PRICE_170);

        (bool can, uint256 expected,) = guard.check(user, id);
        assertTrue(can);
        vm.prank(keeper);
        assertEq(guard.protect(user, id), expected);

        (can,,) = guard.check(user, id);
        assertFalse(can);
    }

    // ------------------------------------------------------------------ config & access

    function test_disable() public {
        _enable(_cfg(WeekendGuard.Mode.ADD_COLLATERAL));
        vm.prank(user);
        guard.disable(id);
        oracle.setPrice(PRICE_170);

        vm.prank(keeper);
        vm.expectRevert(WeekendGuard.NotActive.selector);
        guard.protect(user, id);
    }

    function test_rejectsInvalidConfig() public {
        WeekendGuard.Config memory c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);

        c.triggerHf = 1e18; // must be > 1.0
        vm.prank(user);
        vm.expectRevert(WeekendGuard.InvalidConfig.selector);
        guard.setConfig(id, c);

        c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);
        c.targetHf = c.triggerHf; // must be > trigger
        vm.prank(user);
        vm.expectRevert(WeekendGuard.InvalidConfig.selector);
        guard.setConfig(id, c);

        c = _cfg(WeekendGuard.Mode.ADD_COLLATERAL);
        c.keeperFeeBps = 101; // max 1%
        vm.prank(user);
        vm.expectRevert(WeekendGuard.InvalidConfig.selector);
        guard.setConfig(id, c);

        vm.prank(user);
        vm.expectRevert(WeekendGuard.UnknownMarket.selector);
        guard.setConfig(Id.wrap(bytes32(uint256(123))), _cfg(WeekendGuard.Mode.ADD_COLLATERAL));
    }

    function test_cannotPullMoreThanBudgetFromOtherUsers() public {
        // A user who never configured the guard cannot be touched, even if they approved it
        address other = makeAddr("other");
        morpho.setPosition(id, other, 10e18, 1200e6);
        stock.mint(other, 10e18);
        vm.prank(other);
        stock.approve(address(guard), type(uint256).max);
        oracle.setPrice(PRICE_170);

        vm.prank(keeper);
        vm.expectRevert(WeekendGuard.NotActive.selector);
        guard.protect(other, id);
    }
}
