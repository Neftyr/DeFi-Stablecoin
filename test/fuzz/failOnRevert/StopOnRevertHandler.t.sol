// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Test} from "forge-std/Test.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {NFREngine, AggregatorV3Interface} from "../../../src/NFREngine.sol";
import {NeftyrStableCoin} from "../../../src/NeftyrStableCoin.sol";
import {MockV3Aggregator} from "../../mocks/MockV3Aggregator.sol";
import {console} from "forge-std/console.sol";

/** @dev Handler is going to narrow down the way we call functions (this way we do not waste runs) */

contract StopOnRevertHandler is Test {
    using EnumerableSet for EnumerableSet.AddressSet;

    // Deployed Contracts To Interact With
    NFREngine public nfre;
    NeftyrStableCoin public nfr;
    MockV3Aggregator public ethUsdPriceFeed;
    MockV3Aggregator public btcUsdPriceFeed;
    ERC20Mock public weth;
    ERC20Mock public wbtc;

    // Ghost Variables
    uint96 public constant MAX_DEPOSIT_SIZE = type(uint96).max;

    constructor(NFREngine _nfre, NeftyrStableCoin _nfr) {
        nfre = _nfre;
        nfr = _nfr;

        address[] memory collateralTokens = nfre.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(nfre.getCollateralTokenPriceFeed(address(weth)));
        btcUsdPriceFeed = MockV3Aggregator(nfre.getCollateralTokenPriceFeed(address(wbtc)));
    }

    // FUNCTIONS TO INTERACT WITH

    /////////////////////
    /** @dev NFREngine */
    /////////////////////

    function mintAndDepositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // Must be more than 0
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(nfre), amountCollateral);
        nfre.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = nfre.getCollateralBalanceOfUser(msg.sender, address(collateral));

        amountCollateral = bound(amountCollateral, 0, maxCollateral);

        if (amountCollateral == 0) {
            return;
        }

        nfre.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnNFR(uint256 amountNfr) public {
        // Must Burn More Than 0
        amountNfr = bound(amountNfr, 0, nfr.balanceOf(msg.sender));

        if (amountNfr == 0) {
            return;
        }

        nfre.burnNFR(amountNfr);
    }

    /** @dev Only the NFREngine can mint NFR! */
    // function mintNFR(uint256 amountNfr) public {
    //     amountNfr = bound(amountNfr, 0, MAX_DEPOSIT_SIZE);
    //     vm.prank(nfr.owner());
    //     nfr.mint(msg.sender, amountNfr);
    // }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = nfre.getMinHealthFactor();
        uint256 userHealthFactor = nfre.getHealthFactor(userToBeLiquidated);

        if (userHealthFactor >= minHealthFactor) {
            return;
        }

        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        nfre.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    ////////////////////////////
    /** @dev NeftyrStableCoin */
    ////////////////////////////

    function transfernfr(uint256 amountNfr, address to) public {
        if (to == address(0)) {
            to = address(1);
        }

        amountNfr = bound(amountNfr, 0, nfr.balanceOf(msg.sender));

        vm.prank(msg.sender);
        nfr.transfer(to, amountNfr);
    }

    //////////////////////
    /** @dev Aggregator */
    //////////////////////

    function updateCollateralPrice(uint96 newPrice, uint256 collateralSeed) public {
        int256 intNewPrice = int256(uint256(newPrice));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        MockV3Aggregator priceFeed = MockV3Aggregator(nfre.getCollateralTokenPriceFeed(address(collateral)));

        priceFeed.updateAnswer(intNewPrice);
    }

    ////////////////////////////
    /** @dev Helper Functions */
    ////////////////////////////

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
