// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {Script} from "forge-std/Script.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {NeftyrStableCoin} from "../src/NeftyrStableCoin.sol";
import {NFREngine} from "../src/NFREngine.sol";

contract DeployNFR is Script {
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function run() external returns (NeftyrStableCoin, NFREngine, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig(); // This comes with our mocks!

        (address wethUsdPriceFeed, address wbtcUsdPriceFeed, address weth, address wbtc, uint256 deployerKey) = helperConfig.activeNetworkConfig();
        tokenAddresses = [weth, wbtc];
        priceFeedAddresses = [wethUsdPriceFeed, wbtcUsdPriceFeed];

        vm.startBroadcast(deployerKey);
        NeftyrStableCoin nfr = new NeftyrStableCoin();
        NFREngine nfrEngine = new NFREngine(tokenAddresses, priceFeedAddresses, address(nfr));
        nfr.transferOwnership(address(nfrEngine));
        vm.stopBroadcast();
        return (nfr, nfrEngine, helperConfig);
    }
}
