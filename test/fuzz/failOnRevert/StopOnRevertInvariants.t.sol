// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

// Invariants:
// Protocol must never be insolvent / undercollateralized
// TODO: Users cant create stablecoins with a bad health factor
// TODO: User should only be able to be liquidated if they have a bad health factor

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {NFREngine} from "../../../src/NFREngine.sol";
import {NeftyrStableCoin} from "../../../src/NeftyrStableCoin.sol";
import {HelperConfig} from "../../../script/HelperConfig.s.sol";
import {DeployNFR} from "../../../script/DeployNFR.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/ERC20Mock.sol";
import {StopOnRevertHandler} from "./StopOnRevertHandler.t.sol";
import {console} from "forge-std/console.sol";

/** @dev This will have our invariant aka properties of system that should always holds */

contract StopOnRevertInvariants is StdInvariant, Test {
    NFREngine public nfre;
    NeftyrStableCoin public nfr;
    HelperConfig public helperConfig;

    address public ethUsdPriceFeed;
    address public btcUsdPriceFeed;
    address public weth;
    address public wbtc;

    uint256 amountCollateral = 10 ether;
    uint256 amountToMint = 100 ether;

    uint256 public constant STARTING_USER_BALANCE = 10 ether;
    address public constant USER = address(1);
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;

    // Liquidation
    address public liquidator = makeAddr("liquidator");
    uint256 public collateralToCover = 20 ether;

    StopOnRevertHandler public handler;

    function setUp() external {
        DeployNFR deployer = new DeployNFR();

        (nfr, nfre, helperConfig) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc, ) = helperConfig.activeNetworkConfig();

        handler = new StopOnRevertHandler(nfre, nfr);

        targetContract(address(handler));
    }

    /** @dev We are just calling this to test everything coded in Handler "forge test --mt invariant_protocolMustHaveMoreValueThatTotalSupplyDollars -vv" */
    function invariant_protocolMustHaveMoreValueThatTotalSupplyDollars() public view {
        uint256 totalSupply = nfr.totalSupply();
        uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(nfre));
        uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(nfre));

        uint256 wethValue = nfre.getUsdValue(weth, wethDeposted);
        uint256 wbtcValue = nfre.getUsdValue(wbtc, wbtcDeposited);

        console.log("wethValue: %s", wethValue);
        console.log("wbtcValue: %s", wbtcValue);
        /** @dev Below totalSupply and time mint will be different than 0 only if we enable mintNFR() in Helper! */
        console.log("Total Supply: ", totalSupply);
        console.log("Times mint function called: %s", handler.timesMintIsCalled());

        /** @dev Part for getters that needs restricted parameters */
        console.log("Times getters tested: %s", handler.timesGettersTested());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    function invariant_gettersCantRevert() public view {
        nfre.getAdditionalFeedPrecision();
        nfre.getCollateralTokens();
        nfre.getLiquidationBonus();
        nfre.getLiquidationBonus();
        nfre.getLiquidationThreshold();
        nfre.getMinHealthFactor();
        nfre.getPrecision();
        nfre.getNFR();

        /** @dev Those needs to be tested in helper as they need proper/restricted parameters */
        // nfre.getTokenAmountFromUsd();
        // nfre.getCollateralTokenPriceFeed();
        // nfre.getCollateralBalanceOfUser(); /** Tested ✔ */
        // nfre.getAccountCollateralValue(); /** Tested ✔ */
    }
}
