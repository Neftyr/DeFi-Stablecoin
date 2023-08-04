// SPDX-License-Identifier: MIT

pragma solidity 0.8.19;

import {NeftyrStableCoin} from "./NeftyrStableCoin.sol";
import {OracleLib, AggregatorV3Interface} from "./libraries/OracleLib.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title NFREngine
 * @author Neftyr
 
 * The system is designed to be as minimal as possible.
 * Tokens maintain a 1 token == 1 usd.
  
 * This stablecoin has the properties:
   - Exogenous Collateral
   - Dollar Pegged
   - Algorithmically Stable

 * It is similar to DAI without governance, no fees, only backed by WETH and WBTC.
 * Our NFR system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all the NFR.

 * @notice This contract is the core of NFR System. It handles all the logic for mining and redeeming NFR, As well as depositing & withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */

contract NFREngine is ReentrancyGuard {
    /** @dev Errors */
    error NFREngine__NeedsMoreThanZero();
    error NFREngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error NFREngine__TokenNotAllowed();
    error NFTEngine__TransferFailed();
    error NFREngine__BreaksHealthFactor(uint256 healthFactor);
    error NFREngine__MintFailed();

    /** @dev Events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    /** @dev State Variables */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // It means users have to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountNfrMinted) private s_NFRMinted;
    address[] private s_collateralTokens;

    NeftyrStableCoin private immutable i_nfr;

    /** @dev Modifiers */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) revert NFREngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) revert NFREngine__TokenNotAllowed();
        _;
    }

    /** @dev Constructor */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address nfrAddress) {
        // USD Price Feeds
        if (tokenAddresses.length != priceFeedAddresses.length) revert NFREngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();

        // For example ETH/USD, BTC/USD, MKR/USD
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_nfr = NeftyrStableCoin(nfrAddress);
    }

    /** @dev External Functions */

    /**
     * @notice Following CEI (Checks, Effects, Interactions).
     * @param collateralTokenAddress The address of the token to deposit collateral.
     * @param collateralAmount The amount of collateral to deposit.
     */
    function depositCollateral(
        address collateralTokenAddress,
        uint256 collateralAmount
    ) external moreThanZero(collateralAmount) isAllowedToken(collateralTokenAddress) nonReentrant {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;

        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);

        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) revert NFTEngine__TransferFailed();
    }

    function depositCollateralAndMintNFR() external {}

    function redeemCollateral() external {}

    function redeemCollateralForNFR() external {}

    /**
     * @notice Following CEI (Checks, Effects, Interactions).
     * @param amountNfrToMint The amount of decentralized stablecoin to mint.
     * @notice Must have more collateral value than the minimum threshold.
     */
    function mintNFR(uint256 amountNfrToMint) external moreThanZero(amountNfrToMint) nonReentrant {
        s_NFRMinted[msg.sender] += amountNfrToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_nfr.mint(msg.sender, amountNfrToMint);
        if (!minted) revert NFREngine__MintFailed();
    }

    function burnNFR() external {}

    function liquidate() external {}

    function getHealthFactor() external {}

    /** @dev Internal Functions */

    function _getAccountInformation(address user) private view returns (uint256 totalNfrMinted, uint256 collateralValueInUsd) {
        totalNfrMinted = s_NFRMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Returns how close to liquidation a user is. If a user goes below 1, then they can get liquidated.
     * @param user Address of user to be checked.
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalNfrMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalNfrMinted;
    }

    /**
     * @notice Check health factor (If user have enough collateral) If not -> Revert.
     * @param user Address of user to be checked.
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert NFREngine__BreaksHealthFactor(userHealthFactor);
    }

    /** @dev Public Functions */

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.latestRoundData();
        // 1 ETH = $1000 -> The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }
}
