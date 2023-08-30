// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {NeftyrStableCoin} from "../../src/NeftyrStableCoin.sol";
import {NFREngine} from "../../src/NFREngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployNFR} from "../../script/DeployNFR.s.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {Test, console} from "forge-std/Test.sol";
import {MockFailedMintNFR} from "../mocks/MockFailedMintNFR.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtNFR} from "../mocks/MockMoreDebtNFR.sol";

contract NFREngineTest is StdCheats, Test {
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount);
    event Transfer(address zero, address account, uint256 amount);

    DeployNFR public deployer;
    NeftyrStableCoin public nfr;
    NFREngine public nfre;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    uint256 public amountToMint = 100 ether;

    address public USER = makeAddr("Niferu");
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    address public liquidator = makeAddr("Hastur");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        deployer = new DeployNFR();
        (nfr, nfre, helperConfig) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_USER_BALANCE);
        }

        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        //console.log("User Starting Balance: ", userBalance);

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);

        userBalance = ERC20Mock(weth).balanceOf(USER);
        //console.log("Post User Starting Balance: ", userBalance);
    }

    //////////////////////////////
    /**  @dev Constructor Tests */
    //////////////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthMismatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(NFREngine.NFREngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new NFREngine(tokenAddresses, priceFeedAddresses, address(nfr));
    }

    /////////////////////////////
    /**  @dev Price Feed Tests */
    /////////////////////////////

    function testGetUsdValue() public view {
        uint256 ethAmount = 1 ether;

        uint256 expectedEthUsd = 2000e18;
        uint256 expectedBtcUsd = 1000e18;

        uint256 ethUsdValue = nfre.getUsdValue(weth, ethAmount);
        uint256 btcUsdValue = nfre.getUsdValue(wbtc, ethAmount);

        console.log("1 WETH USD Value: ", ethUsdValue);
        console.log("1 WBTC USD Value: ", btcUsdValue);

        assert(ethUsdValue == expectedEthUsd);
        assert(btcUsdValue == expectedBtcUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // 100 / 2000 = 0.05
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = nfre.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    ///////////////////////////
    /**  @dev Mint NFR Tests */
    ///////////////////////////

    function testRevertsIfMintFails() public {
        // Arrange - Setup
        MockFailedMintNFR mockNfr = new MockFailedMintNFR();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;

        vm.prank(owner);
        NFREngine mockNfre = new NFREngine(tokenAddresses, priceFeedAddresses, address(mockNfr));
        mockNfr.transferOwnership(address(mockNfre));

        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockNfre), COLLATERAL_AMOUNT);

        vm.expectRevert(NFREngine.NFREngine__MintFailed.selector);
        mockNfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfre.mintNFR(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (COLLATERAL_AMOUNT * (uint256(price) * nfre.getAdditionalFeedPrecision())) / nfre.getPrecision();

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateral(weth, COLLATERAL_AMOUNT);

        uint256 expectedHealthFactor = nfre.calculateHealthFactor(amountToMint, nfre.getUsdValue(weth, COLLATERAL_AMOUNT));
        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__BreaksHealthFactor.selector, expectedHealthFactor));
        nfre.mintNFR(amountToMint);
        vm.stopPrank();
    }

    function testCanMintNfr() public depositedCollateral {
        vm.prank(USER);
        nfre.mintNFR(amountToMint);

        uint256 userBalance = nfr.balanceOf(USER);
        assertEq(userBalance, amountToMint);
    }

    ////////////////////////////////
    /**  @dev Health Factor Tests */
    ////////////////////////////////

    function testHealthFactorCalculatesCorrectly() public {
        uint256 health = nfre.getHealthFactor(USER);

        assertEq(health, type(uint256).max);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(USER);
        uint256 currentHealth = nfre.calculateHealthFactor(totalNfrMinted, collateralValueInUsd);
        uint256 postHealth = nfre.getHealthFactor(USER);

        assertEq(currentHealth, postHealth);
        assertEq(postHealth, (((collateralValueInUsd * 50) / 100) * 1e18) / totalNfrMinted);
    }

    function testHealthFactorCanGoBelowOne() public depositedCollateralAndMintedNfr {
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Rememeber, we need $150 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = nfre.getHealthFactor(USER);
        // $180 collateral / 200 debt = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    /////////////////////////////////////
    /**  @dev Deposit Collateral Tests */
    /////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);

        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfre.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, STARTING_USER_BALANCE);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__TokenNotAllowed.selector, address(randomToken)));
        nfre.depositCollateral(address(randomToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = nfr.balanceOf(USER);

        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(USER);
        uint256 expectedDepositedAmount = nfre.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalNfrMinted, 0);
        assertEq(expectedDepositedAmount, COLLATERAL_AMOUNT);
    }

    function testCanDepositCollateralAndMintNFR() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        vm.expectEmit(false, false, false, false, address(nfre));
        emit CollateralDeposited(USER, weth, COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(USER);
        uint256 expectedDepositedAmount = nfre.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalNfrMinted, amountToMint);
        assertEq(expectedDepositedAmount, COLLATERAL_AMOUNT);
    }

    function testRevertsDepositAndMintIfHealthFactorIsBroken() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (COLLATERAL_AMOUNT * (uint256(price) * nfre.getAdditionalFeedPrecision())) / nfre.getPrecision();
        console.log("Amt To Mint: ", amountToMint);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);

        uint256 expectedHealthFactor = nfre.calculateHealthFactor(amountToMint, nfre.getUsdValue(weth, COLLATERAL_AMOUNT));
        console.log("Expected Health Factor: ", expectedHealthFactor, "Min Health Value: ", 1e18);

        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__BreaksHealthFactor.selector, expectedHealthFactor));
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);

        vm.stopPrank();
    }

    function testRevertsIfTransferFromFails() public {
        // Arrange - Setup
        address owner = msg.sender;

        vm.prank(owner);
        MockFailedTransferFrom mockNfr = new MockFailedTransferFrom();

        tokenAddresses = [address(mockNfr)];
        priceFeedAddresses = [ethUsdPriceFeed];

        vm.prank(owner);
        NFREngine mockNfre = new NFREngine(tokenAddresses, priceFeedAddresses, address(mockNfr));

        mockNfr.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockNfr.transferOwnership(address(mockNfre));

        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockNfr)).approve(address(mockNfre), COLLATERAL_AMOUNT);

        // Act / Assert
        vm.expectRevert(NFREngine.NFREngine__TransferFailed.selector);
        mockNfre.depositCollateral(address(mockNfr), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedNfr() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
        _;
    }

    ////////////////////////////////////
    /**  @dev Redeem Collateral Tests */
    ////////////////////////////////////

    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockNfr = new MockFailedTransfer();
        tokenAddresses = [address(mockNfr)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        NFREngine mockNfre = new NFREngine(tokenAddresses, priceFeedAddresses, address(mockNfr));
        mockNfr.mint(USER, COLLATERAL_AMOUNT);

        vm.prank(owner);
        mockNfr.transferOwnership(address(mockNfre));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockNfr)).approve(address(mockNfre), COLLATERAL_AMOUNT);
        // Act / Assert
        mockNfre.depositCollateral(address(mockNfr), COLLATERAL_AMOUNT);
        vm.expectRevert(NFREngine.NFREngine__TransferFailed.selector);
        mockNfre.redeemCollateral(address(mockNfr), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfre.redeemCollateral(weth, 0);

        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);

        uint256 userPrevBal = ERC20Mock(weth).balanceOf(USER);
        console.log("Previous Balance: ", userPrevBal);
        nfre.redeemCollateral(weth, COLLATERAL_AMOUNT);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        console.log("Post Balance: ", userBalance);

        vm.stopPrank();

        assertEq(userBalance, COLLATERAL_AMOUNT);
    }

    function testRevertsRedeemIfHealthFactorBroken() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        /** @dev Below value of healthFactor is 0 because it calculates with redeemed collateral? */
        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__BreaksHealthFactor.selector, 0));
        nfre.redeemCollateral(weth, COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(nfre));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        nfre.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanBrunNFRAndRedeemForNFR() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(USER);
        assertEq(totalNfrMinted, amountToMint);
        assertEq(collateralValueInUsd, 20000e18);

        nfr.approve(address(nfre), amountToMint);
        nfre.redeemCollateralForNFR(weth, 0.1 ether, 1 ether);

        (uint256 postTotalNfrMinted, uint256 postCollateralValueInUsd) = nfre.getAccountInformation(USER);
        assertEq(postTotalNfrMinted, amountToMint - 1 ether);
        assertEq(postCollateralValueInUsd, 20000e18 - 20000e16);
        vm.stopPrank();
    }

    /////////////////////////////////////////////
    /**  @dev Collateral Min Level Check Tests */
    /////////////////////////////////////////////

    function testRevertsIfNotEnoughCollateralToRedeem() public {
        vm.startPrank(USER);
        vm.expectRevert(NFREngine.NFREngine__NotEnoughCollateralToRedeem.selector);
        nfre.redeemCollateral(weth, COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    //////////////////////////////
    /**  @dev Burn Tokens Tests */
    //////////////////////////////

    function testRevertsBurnIfNoTokensMinted() public {
        vm.startPrank(USER);

        vm.expectRevert(NFREngine.NFREngine__NoTokensToBurn.selector);
        nfre.burnNFR(amountToMint);

        vm.stopPrank();
    }

    function testCanBrunNFR() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        nfr.approve(address(nfre), amountToMint);
        nfre.burnNFR(amountToMint);

        vm.stopPrank();
    }

    //////////////////////////////
    /**  @dev Liquidation Tests */
    //////////////////////////////

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        /** @dev We are crashing ETH price -> 1 ETH = $18 */
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = nfre.getHealthFactor(USER);

        /** @dev Setting up liquidator */
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(nfre), collateralToCover);
        nfre.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);
        nfr.approve(address(nfre), amountToMint);
        /** @dev We are covering user whole debt */
        nfre.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
        _;
    }

    /** @dev ToDo: Add asserts to check updated values */
    function testCanLiquidateUserAndUpdatesValuesAccordingly() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        /** @dev Stats Before Liquidation */
        console.log("----------------------------------- User -----------------------------------");
        uint256 userBal = ERC20Mock(weth).balanceOf(USER);
        console.log("User WETH Balance Before Liquidation: ", userBal);
        uint256 userBalanceBefore = nfre.getCollateralBalanceOfUser(USER, weth);
        console.log("User Collateral Balance: ", userBalanceBefore);
        (uint256 totalNfrMintedBefore, uint256 collateralValueInUsdBefore) = nfre.getAccountInformation(USER);
        console.log("User Total NFR minted: ", totalNfrMintedBefore);
        console.log("User Collateral Value In USD: ", collateralValueInUsdBefore);

        /** @dev Crashing ETH price */
        console.log("");
        console.log("----------------------------------- Health Factor -----------------------------------");
        uint256 userHealthFactorBefore = nfre.getHealthFactor(USER);
        console.log("User Health Factor Before Price Crash: ", userHealthFactorBefore);
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = nfre.getHealthFactor(USER);
        console.log("User Health Factor After Crash: ", userHealthFactor);
        assert(userHealthFactorBefore > userHealthFactor);

        /** @dev Preparing Liquidator */
        vm.startPrank(liquidator);
        ERC20Mock(weth).mint(liquidator, collateralToCover);
        ERC20Mock(weth).approve(address(nfre), collateralToCover);
        nfre.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);

        /** @dev Reading Liquidator Stats */
        console.log("");
        console.log("----------------------------------- Liquidator -----------------------------------");
        uint256 liqBalBefore = ERC20Mock(weth).balanceOf(liquidator);
        console.log("Liquidator WETH Balance Before Liquidation: ", liqBalBefore);
        uint256 liquidatorBalance = nfre.getCollateralBalanceOfUser(liquidator, weth);
        console.log("Liquidator Collateral Balance: ", liquidatorBalance);
        (uint256 totalNfrMintedL, uint256 collateralValueInUsdL) = nfre.getAccountInformation(liquidator);
        console.log("Liquidator Total NFR minted: ", totalNfrMintedL);
        console.log("Liquidator Collateral Value In USD: ", collateralValueInUsdL);

        /** @dev Liquidation */
        nfr.approve(address(nfre), amountToMint);
        nfre.liquidate(weth, USER, amountToMint);
        vm.stopPrank();

        /** @dev Post Liquidation Stats */
        console.log("");
        console.log("----------------------------------- User After Liquidation -----------------------------------");
        userBal = ERC20Mock(weth).balanceOf(USER);
        console.log("User WETH Balance After Liquidation: ", userBal);
        // Redeem Collateral from user -> liquidator
        uint256 userBalance = nfre.getCollateralBalanceOfUser(USER, weth);
        console.log("User Collateral Balance: ", userBalance);
        // Burn NFR tokens from user -> liquidator
        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(USER);
        console.log("User Total NFR minted: ", totalNfrMinted);
        console.log("User Collateral Value In USD: ", collateralValueInUsd);
        console.log("");
        console.log("----------------------------------- Health Factor After Liquidation -----------------------------------");
        uint256 userHp = nfre.getHealthFactor(USER);
        console.log("User Health Factor After Liquidation: ", userHp);
        console.log("");
        console.log("----------------------------------- Liquidator After Liquidation -----------------------------------");
        uint256 liqBal = ERC20Mock(weth).balanceOf(liquidator);
        console.log("Liquidator WETH Balance After Liquidation: ", liqBal);
        liquidatorBalance = nfre.getCollateralBalanceOfUser(liquidator, weth);
        console.log("Liquidator Collateral Balance: ", liquidatorBalance);
        (totalNfrMintedL, collateralValueInUsdL) = nfre.getAccountInformation(liquidator);
        console.log("Liquidator Total NFR minted: ", totalNfrMintedL);
        console.log("Liquidator Collateral Value In USD: ", collateralValueInUsdL);

        // User Asserts
        assert(userBalanceBefore > userBalance);
        assert(totalNfrMintedBefore > totalNfrMinted && totalNfrMinted == 0);
        assert(collateralValueInUsdBefore > collateralValueInUsd);
        assert(userHp > userHealthFactor && userHp > userHealthFactorBefore);

        // Liquidator Asserts
        uint256 expectedWeth = nfre.getTokenAmountFromUsd(weth, amountToMint) + (nfre.getTokenAmountFromUsd(weth, amountToMint) / nfre.getLiquidationBonus());
        assert(liqBal > liqBalBefore && liqBal == expectedWeth);
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(liquidator);
        uint256 expectedWeth = nfre.getTokenAmountFromUsd(weth, amountToMint) + (nfre.getTokenAmountFromUsd(weth, amountToMint) / nfre.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;

        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = nfre.getTokenAmountFromUsd(weth, amountToMint) +
            (nfre.getTokenAmountFromUsd(weth, amountToMint) / nfre.getLiquidationBonus());

        uint256 usdAmountLiquidated = nfre.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = nfre.getUsdValue(weth, COLLATERAL_AMOUNT) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = nfre.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70000000000000000020;

        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorTakesOnUsersDebt() public liquidated {
        (uint256 liquidatorNfrMinted, ) = nfre.getAccountInformation(liquidator);

        assertEq(liquidatorNfrMinted, amountToMint);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userNfrMinted, ) = nfre.getAccountInformation(USER);

        assertEq(userNfrMinted, 0);
    }

    function testRevertsIfHealthFactorOk() public {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);

        ERC20Mock(weth).approve(address(nfre), collateralToCover);
        nfre.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);
        nfr.approve(address(nfre), amountToMint);

        vm.expectRevert(NFREngine.NFREngine__HealthFactorOk.selector);
        nfre.liquidate(weth, USER, amountToMint);

        vm.stopPrank();
    }

    function testRevertsIfHealthFactorNotImprovedAfterLiquidation() public {
        // Arrange - Setup
        MockMoreDebtNFR mockNFR = new MockMoreDebtNFR(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;

        vm.prank(owner);
        NFREngine mockNFRe = new NFREngine(tokenAddresses, priceFeedAddresses, address(mockNFR));
        mockNFR.transferOwnership(address(mockNFRe));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockNFRe), COLLATERAL_AMOUNT);
        mockNFRe.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(mockNFRe), collateralToCover);
        uint256 debtToCover = 10 ether;
        mockNFRe.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);
        mockNFR.approve(address(mockNFRe), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        vm.expectRevert(NFREngine.NFREngine__HealthFactorNotImproved.selector);
        mockNFRe.liquidate(weth, USER, debtToCover);
        vm.stopPrank();
    }

    function testRevertsLiquidateIfHealthFactorIsBroken() public {}

    //////////////////////////
    /**  @dev Getters Tests */
    //////////////////////////

    function testCanGetTokenAmountFromUsd() public {
        vm.startPrank(USER);
        uint256 tokenAmount = nfre.getTokenAmountFromUsd(weth, 1 ether);
        vm.stopPrank();

        assertEq(tokenAmount, 0.0005 ether);
    }

    function testCanGetAccountCollateralValue() public {
        vm.startPrank(USER);

        uint256 collateralValue = nfre.getAccountCollateralValue(msg.sender);
        console.log("User Collateral Value: ", collateralValue);
        assertEq(collateralValue, 0);

        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint256 postCollateralValue = nfre.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = nfre.getUsdValue(weth, COLLATERAL_AMOUNT);
        console.log("User Post Collateral Value: ", postCollateralValue, "Expected: ", expectedCollateralValue);
        assertEq(postCollateralValue, expectedCollateralValue);
    }

    function testGetNFR() public {
        address nfrAddress = nfre.getNFR();
        assertEq(nfrAddress, address(nfr));
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = nfre.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = nfre.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfre), COLLATERAL_AMOUNT);
        nfre.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        uint256 collateralBalance = nfre.getCollateralBalanceOfUser(USER, weth);
        assertEq(collateralBalance, COLLATERAL_AMOUNT);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = nfre.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = nfre.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }
}
