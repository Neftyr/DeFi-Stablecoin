// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {NeftyrStableCoin} from "../../src/NeftyrStableCoin.sol";
import {NFREngine} from "../../src/NFREngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {DeployNFR} from "../../script/DeployNFR.s.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

contract NFREngineTest is StdCheats, Test {
    DeployNFR public deployer;
    NeftyrStableCoin public neftyrStableCoin;
    NFREngine public nfrEngine;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;
    uint256 public deployerKey;

    address public USER = makeAddr("Niferu");
    uint256 public constant COLLATERAL_AMOUNT = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;

    function setUp() external {
        deployer = new DeployNFR();
        (neftyrStableCoin, nfrEngine, helperConfig) = deployer.run();

        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, deployerKey) = helperConfig.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    /**  @dev Price Feed Tests */

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

    /**  @dev Deposit Collateral Tests */

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(nfrEngine), COLLATERAL_AMOUNT);

        vm.expectRevert(NFREngine.NFREngine__NeedsMoreThanZero.selector);
        nfrEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
