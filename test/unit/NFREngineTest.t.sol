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
import {Vm} from "forge-std/Vm.sol";
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
    NFREngine public nfrEngine;
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

    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    function setUp() external {
        deployer = new DeployNFR();
        (nfr, nfrEngine, helperConfig) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        if (block.chainid == 31337) {
            vm.deal(USER, STARTING_USER_BALANCE);
        }

        ERC20Mock(weth).mint(USER, STARTING_USER_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_USER_BALANCE);
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

        uint256 ethUsdValue = nfrEngine.getUsdValue(weth, ethAmount);
        uint256 btcUsdValue = nfrEngine.getUsdValue(wbtc, ethAmount);

        console.log("1 WETH USD Value: ", ethUsdValue);
        console.log("1 WBTC USD Value: ", btcUsdValue);

        assert(ethUsdValue == expectedEthUsd);
        assert(btcUsdValue == expectedBtcUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        // 100 / 2000 = 0.05
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = nfrEngine.getTokenAmountFromUsd(weth, usdAmount);

        assertEq(expectedWeth, actualWeth);
    }

    /////////////////////////////////////
    /**  @dev Deposit Collateral Tests */
    /////////////////////////////////////

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfrEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock randomToken = new ERC20Mock("RAN", "RAN", USER, STARTING_USER_BALANCE);

        vm.startPrank(USER);
        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__TokenNotAllowed.selector, address(randomToken)));
        nfrEngine.depositCollateral(address(randomToken), COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanDepositCollateralWithoutMinting() public depositedCollateral {
        uint256 userBalance = nfr.balanceOf(USER);

        assertEq(userBalance, 0);
    }

    function testCanDepositedCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfrEngine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = nfrEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalNfrMinted, 0);
        assertEq(expectedDepositedAmount, COLLATERAL_AMOUNT);
    }

    function testCanDepositCollateralAndMintNFR() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        vm.expectEmit(false, false, false, false, address(nfrEngine));
        emit CollateralDeposited(USER, weth, COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfrEngine.getAccountInformation(USER);
        uint256 expectedDepositedAmount = nfrEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);

        assertEq(totalNfrMinted, amountToMint);
        assertEq(expectedDepositedAmount, COLLATERAL_AMOUNT);
    }

    function testHealthFactorCalculatesCorrectly() public {
        uint256 health = nfrEngine.getHealthFactor(USER);

        assertEq(health, type(uint256).max);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfrEngine.getAccountInformation(USER);
        uint256 currentHealth = nfrEngine.calculateHealthFactor(totalNfrMinted, collateralValueInUsd);
        uint256 postHealth = nfrEngine.getHealthFactor(USER);

        assertEq(currentHealth, postHealth);
        assertEq(postHealth, (((collateralValueInUsd * 50) / 100) * 1e18) / totalNfrMinted);
    }

    function testRevertsDepositAndMintIfHealthFactorIsBroken() public {
        (, int256 price, , , ) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (COLLATERAL_AMOUNT * (uint256(price) * nfrEngine.getAdditionalFeedPrecision())) / nfrEngine.getPrecision();
        console.log("Amt To Mint: ", amountToMint);

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);

        uint256 expectedHealthFactor = nfrEngine.calculateHealthFactor(amountToMint, nfrEngine.getUsdValue(weth, COLLATERAL_AMOUNT));
        console.log("Expected Health Factor: ", expectedHealthFactor, "Min Health Value: ", 1e18);

        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__BreaksHealthFactor.selector, expectedHealthFactor));
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);

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
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
        _;
    }

    modifier depositedCollateralAndMintedNfr() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();
        _;
    }

    ////////////////////////////////////
    /**  @dev Redeem Collateral Tests */
    ////////////////////////////////////

    function testRevertsIfRedeemAmountIsZero() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfrEngine.redeemCollateral(weth, 0);

        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);

        uint256 userPrevBal = ERC20Mock(weth).balanceOf(USER);
        console.log("Previous Balance: ", userPrevBal);
        nfrEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        console.log("Post Balance: ", userBalance);

        vm.stopPrank();

        assertEq(userBalance, COLLATERAL_AMOUNT);
    }

    function testRevertsRedeemIfHealthFactorBroken() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        /** @dev Below value of healthFactor is 0 because it calculates with redeemed collateral? */
        vm.expectRevert(abi.encodeWithSelector(NFREngine.NFREngine__BreaksHealthFactor.selector, 0));
        nfrEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositedCollateral {
        vm.expectEmit(true, true, true, true, address(nfrEngine));
        emit CollateralRedeemed(USER, USER, weth, COLLATERAL_AMOUNT);
        vm.startPrank(USER);
        nfrEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();
    }

    function testCanBrunNFRAndRedeemForNFR() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfrEngine.getAccountInformation(USER);
        assertEq(totalNfrMinted, amountToMint);
        assertEq(collateralValueInUsd, 20000e18);

        nfr.approve(address(nfrEngine), amountToMint);
        nfrEngine.redeemCollateralForNFR(weth, 0.1 ether, 1 ether);

        (uint256 postTotalNfrMinted, uint256 postCollateralValueInUsd) = nfrEngine.getAccountInformation(USER);
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
        nfrEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);

        vm.stopPrank();
    }

    //////////////////////////////
    /**  @dev Burn Tokens Tests */
    //////////////////////////////

    function testRevertsBurnIfNoTokensMinted() public {
        vm.startPrank(USER);

        vm.expectRevert(NFREngine.NFREngine__NoTokensToBurn.selector);
        nfrEngine.burnNFR(amountToMint);

        vm.stopPrank();
    }

    function testCanBrunNFR() public depositedCollateralAndMintedNfr {
        vm.startPrank(USER);

        nfr.approve(address(nfrEngine), amountToMint);
        nfrEngine.burnNFR(amountToMint);

        vm.stopPrank();
    }

    //////////////////////////////
    /**  @dev Liquidation Tests */
    //////////////////////////////

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        /** @dev We are crashing ETH price -> 1 ETH = $18 */
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = nfrEngine.getHealthFactor(USER);

        /** @dev Setting up liquidator */
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(nfrEngine), collateralToCover);
        nfrEngine.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);
        nfr.approve(address(nfrEngine), amountToMint);
        /** @dev We are covering their whole debt */
        nfrEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();
        _;
    }

    /** @dev BELOW TO BE FIXED !!! */
    function testCanLiquidateUserAndUpdatesValuesAccordingly() public {
        // 👍✔ -> windows + ; ℉℃⁂µ※
        uint256 debt = 1000 ether;

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        vm.stopPrank();

        uint256 userHealthFactorBefore = nfrEngine.getHealthFactor(USER);
        console.log("User Health Factor Before Price Crash: ", userHealthFactorBefore);
        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = nfrEngine.getHealthFactor(USER);
        console.log("User Health Factor: ", userHealthFactor);

        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateralAndMintNFR(weth, COLLATERAL_AMOUNT, amountToMint);
        nfr.approve(address(nfrEngine), amountToMint);
        nfrEngine.liquidate(weth, USER, amountToMint);
        vm.stopPrank();

        // redeemCollateral from user -> liquidator
        // burn NFR tokens from user -> liquidator
    }

    function testRevertsIfHealthFactorOk() public {
        ERC20Mock(weth).mint(liquidator, collateralToCover);

        vm.startPrank(liquidator);

        ERC20Mock(weth).approve(address(nfrEngine), collateralToCover);
        nfrEngine.depositCollateralAndMintNFR(weth, collateralToCover, amountToMint);
        nfr.approve(address(nfrEngine), amountToMint);

        vm.expectRevert(NFREngine.NFREngine__HealthFactorOk.selector);
        nfrEngine.liquidate(weth, USER, amountToMint);

        vm.stopPrank();
    }

    function testRevertsLiquidateIfHealthFactorIsBroken() public {}

    //////////////////////////
    /**  @dev Getters Tests */
    //////////////////////////

    function testCanGetTokenAmountFromUsd() public {
        vm.startPrank(USER);
        uint256 tokenAmount = nfrEngine.getTokenAmountFromUsd(weth, 1 ether);

        assertEq(tokenAmount, 0.0005 ether);
        vm.stopPrank();
    }

    function testCanGetAccountCollateralValue() public {
        vm.startPrank(USER);

        uint256 collateralValue = nfrEngine.getAccountCollateralValue(msg.sender);
        console.log("User Collateral Value: ", collateralValue);
        assertEq(collateralValue, 0);

        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);
        nfrEngine.depositCollateral(weth, COLLATERAL_AMOUNT);
        vm.stopPrank();

        uint256 postCollateralValue = nfrEngine.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = nfrEngine.getUsdValue(weth, COLLATERAL_AMOUNT);
        console.log("User Post Collateral Value: ", postCollateralValue, "Expected: ", expectedCollateralValue);
        assertEq(postCollateralValue, expectedCollateralValue);
    }

    function testGetNFR() public {
        address nfrAddress = nfrEngine.getNFR();
        assertEq(nfrAddress, address(nfr));
    }
}
