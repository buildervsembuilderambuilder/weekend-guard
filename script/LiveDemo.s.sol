// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {WeekendGuard} from "../src/WeekendGuard.sol";
import {Id, MarketParams} from "../src/interfaces/IMorpho.sol";
import {MockERC20, MockOracle} from "../test/mocks/Mocks.sol";

interface IMorphoFull {
    function createMarket(MarketParams memory marketParams) external;
    function supply(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, bytes memory data)
        external
        returns (uint256, uint256);
    function supplyCollateral(MarketParams memory mp, uint256 assets, address onBehalf, bytes memory data) external;
    function borrow(MarketParams memory mp, uint256 assets, uint256 shares, address onBehalf, address receiver)
        external
        returns (uint256, uint256);
}

/// End-to-end WeekendGuard demo on Robinhood Chain testnet, run from a single wallet.
///  1. Deploy a mintable demo stock token, a demo stablecoin and a settable oracle ($200)
///  2. Create a Morpho market: borrow dUSD against dSTOCK, LLTV 77%
///  3. Act as lender (supply 5,000 dUSD) and as borrower (10 dSTOCK collateral, borrow 1,200 dUSD => HF 1.283)
///  4. Approve the guard and setConfig(ADD_COLLATERAL, trigger 1.15, target 1.4)
///  5. Oracle drops to $170 (HF 1.091 < 1.15) => protect() tops the position back up to HF 1.4
///
/// Usage:
///   export ROBINHOOD_TESTNET_RPC=https://rpc.testnet.chain.robinhood.com
///   forge script script/LiveDemo.s.sol --rpc-url robinhood_testnet --broadcast --interactive
contract LiveDemo is Script {
    IMorphoFull constant MORPHO = IMorphoFull(0xCff25c2c38c1D8966Fc9A205692B57Bde52A33Bb);
    WeekendGuard constant GUARD = WeekendGuard(0x7A0f008C5e8e69D57562c0d129dd90a898eC4cB7);
    address constant IRM = 0x71F1E7058424cbaeBe992520B847a4947b6Db27D;
    uint256 constant LLTV = 0.77e18;

    // 1 dSTOCK (18 dec) in dUSD (6 dec), Morpho 1e36 scale: $1 => 1e24
    uint256 constant PRICE_200 = 200e24;
    uint256 constant PRICE_170 = 170e24;

    function run() external {
        vm.startBroadcast();
        address me = msg.sender;

        // 1. tokens + oracle
        MockERC20 stock = new MockERC20("WeekendGuard Demo Stock", "dSTOCK", 18);
        MockERC20 usd = new MockERC20("WeekendGuard Demo USD", "dUSD", 6);
        MockOracle oracle = new MockOracle();
        oracle.setPrice(PRICE_200);

        // 2. market
        MarketParams memory mp = MarketParams({
            loanToken: address(usd),
            collateralToken: address(stock),
            oracle: address(oracle),
            irm: IRM,
            lltv: LLTV
        });
        MORPHO.createMarket(mp);
        Id id = Id.wrap(keccak256(abi.encode(mp)));

        // 3. liquidity + borrower position
        usd.mint(me, 5_000e6);
        stock.mint(me, 100e18);
        usd.approve(address(MORPHO), type(uint256).max);
        stock.approve(address(MORPHO), type(uint256).max);
        MORPHO.supply(mp, 5_000e6, 0, me, "");
        MORPHO.supplyCollateral(mp, 10e18, me, "");
        MORPHO.borrow(mp, 1_200e6, 0, me, me);

        // 4. opt into WeekendGuard
        stock.approve(address(GUARD), 50e18);
        GUARD.setConfig(
            id,
            WeekendGuard.Config({
                active: false, // set by the contract
                mode: WeekendGuard.Mode.ADD_COLLATERAL,
                triggerHf: 1.15e18,
                targetHf: 1.4e18,
                weekendGapBps: 1500,
                keeperFeeBps: 30,
                cooldown: 1 hours,
                maxPerAction: 20e18,
                budgetLeft: 50e18
            })
        );
        console2.log("HF at $200:", GUARD.healthFactor(me, id));

        // 5. price shock + protection
        oracle.setPrice(PRICE_170);
        console2.log("HF at $170 (before protect):", GUARD.healthFactor(me, id));
        uint256 added = GUARD.protect(me, id);
        console2.log("collateral added (1e18):", added);
        console2.log("HF after protect:", GUARD.healthFactor(me, id));

        vm.stopBroadcast();

        console2.log("dSTOCK:", address(stock));
        console2.log("dUSD:", address(usd));
        console2.log("oracle:", address(oracle));
        console2.log("market id:");
        console2.logBytes32(Id.unwrap(id));
    }
}
