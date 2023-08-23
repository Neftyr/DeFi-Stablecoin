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

    function testHealthFactorRevertsIfNoMintedNFR() public {
        uint256 health = nfrEngine.getHealthFactor(USER);
        console.log("Health Factor: ", health);

        assertEq(health, 1e18);
    }

    // Try to calculate it to understand it
    function testRevertsMintIfHealthFactorIsBroken() public {
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

    // // This test needs it's own setup
    // function testRevertsIfTransferFromFails() public {
    //     // Arrange - Setup
    //     address owner = msg.sender;
    //     vm.prank(owner);
    //     MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
    //     tokenAddresses = [address(mockDsc)];
    //     feedAddresses = [ethUsdPriceFeed];
    //     vm.prank(owner);
    //     nfrEnginengine mocknfrEngine = new nfrEnginengine(tokenAddresses, feedAddresses, address(mockDsc));
    //     mockDsc.mint(user, amountCollateral);

    //     vm.prank(owner);
    //     mockDsc.transferOwnership(address(mocknfrEngine));
    //     // Arrange - User
    //     vm.startPrank(user);
    //     ERC20Mock(address(mockDsc)).approve(address(mocknfrEngine), amountCollateral);
    //     // Act / Assert
    //     vm.expectRevert(nfrEnginengine.nfrEnginengine__TransferFailed.selector);
    //     mocknfrEngine.depositCollateral(address(mockDsc), amountCollateral);
    //     vm.stopPrank();
    // }

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

    // function testCanRedeemCollateral() public depositedCollateral {
    //     vm.startPrank(USER);

    //     //uint256 collateral_to_redeem = 1 ether;
    //     //console.log("Redeem: ", COLLATERAL_AMOUNT);
    //     nfrEngine.redeemCollateral(weth, 10);
    //     uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
    //     console.log("Balance: ", userBalance);
    //     vm.stopPrank();
    // }

    function testCanRedeemCollateral() public depositedCollateral {
        vm.startPrank(USER);

        uint256 userPrevBal = ERC20Mock(weth).balanceOf(USER);
        console.log("Prev Bal: ", userPrevBal);
        nfrEngine.redeemCollateral(weth, COLLATERAL_AMOUNT);
        uint256 userBalance = ERC20Mock(weth).balanceOf(USER);
        console.log("Post Balance: ", userBalance);

        vm.stopPrank();

        assertEq(userBalance, COLLATERAL_AMOUNT);
    }

    function testRevertsRedeemIfHealthFactorBroken() public {}

    function testCanBrunNFRAndRedeemForNFR() public {}

    function testRevertsBurnIfHealthFactorBroken() public {}
}
