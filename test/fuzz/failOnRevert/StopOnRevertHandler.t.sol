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

    /** @dev Ghost Variables */
    // Checking if below function has been tested
    uint256 public timesMintIsCalled;
    uint256 public timesGettersTested;
    address[] usersWithCollateralDeposited;

    // We are doing uint96 because in case of further deposits we avoid overextending uint256
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
        /** @dev Bound is function from utils and it just gives us x -> bound(x, min, max) to be in min/max range */
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_SIZE);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(nfre), amountCollateral);
        nfre.depositCollateral(address(collateral), amountCollateral);

        /** @dev Below loop will be enormous because we are running a lot of tests, so it is better to just push every address (we will have a lot of duplicates) */
        // if (usersWithCollateralDeposited.length > 0) {
        //     for (uint i = 0; i < usersWithCollateralDeposited.length; i++) {
        //         if (msg.sender == usersWithCollateralDeposited[i]) return;
        //         usersWithCollateralDeposited.push(msg.sender);
        //     }
        // } else {
        //     usersWithCollateralDeposited.push(msg.sender);
        // }

        usersWithCollateralDeposited.push(msg.sender);
        vm.stopPrank();
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateral = nfre.getCollateralBalanceOfUser(msg.sender, address(collateral));

        // We are making range (0 - max) instead of (1 - max) to avoid making maxCollateral < 1 as it will crash bound() function
        amountCollateral = bound(amountCollateral, 0, maxCollateral);

        if (amountCollateral == 0) return;

        nfre.redeemCollateral(address(collateral), amountCollateral);
    }

    function burnNFR(uint256 amountNfr) public {
        // Must Burn More Than 0
        amountNfr = bound(amountNfr, 0, nfr.balanceOf(msg.sender));

        if (amountNfr == 0) return;

        nfre.burnNFR(amountNfr);
    }

    /** @dev TO RUN BELOW COMMENT OUT: liquidate, transferNfr, updateCollateralPrice */
    /** @dev Only user with deposited collateral can mint NFR */
    // function mintNFR(uint256 amountNfr, uint256 addressSeed) public {
    //     if (usersWithCollateralDeposited.length == 0) return;

    //     address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
    //     (uint256 totalNfrMinted, uint256 collateralValueInUsd) = nfre.getAccountInformation(sender);
    //     int256 maxNfrToMint = (int256(collateralValueInUsd) / 2) - int256(totalNfrMinted);

    //     if (maxNfrToMint < 0) return;

    //     amountNfr = bound(amountNfr, 0, uint256(maxNfrToMint));

    //     if (amountNfr == 0) return;

    //     vm.prank(sender);
    //     nfre.mintNFR(amountNfr);
    //     timesMintIsCalled++;
    // }

    /** @dev Only the NFREngine can mint NFR! Below will be crashing other functions as we break health factor by minting*/
    // function mintNFR(uint256 amountNfr) public {
    //     amountNfr = bound(amountNfr, 0, MAX_DEPOSIT_SIZE);

    //     vm.prank(nfr.owner());
    //     nfr.mint(msg.sender, amountNfr);
    //     timesMintIsCalled++;
    // }

    function liquidate(uint256 collateralSeed, address userToBeLiquidated, uint256 debtToCover) public {
        uint256 minHealthFactor = nfre.getMinHealthFactor();
        uint256 userHealthFactor = nfre.getHealthFactor(userToBeLiquidated);

        if (userHealthFactor >= minHealthFactor) return;

        debtToCover = bound(debtToCover, 1, uint256(type(uint96).max));
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        nfre.liquidate(address(collateral), userToBeLiquidated, debtToCover);
    }

    ////////////////////////////
    /** @dev NeftyrStableCoin */
    ////////////////////////////

    function transferNfr(address to, uint256 amountNfr) public {
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

    /////////////////////////////
    /** @dev Getters Functions */
    /////////////////////////////

    function getCollateralBalanceOfUser(address user, uint256 collateralSeed) public {
        /** @dev We do not need to restrict below */
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);

        nfre.getCollateralBalanceOfUser(user, address(collateral));
        timesGettersTested++;
    }

    function getAccountCollateralValue(address user) public {
        nfre.getAccountCollateralValue(user);
        timesGettersTested++;
    }
}
