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
    error NFREngine__TransferFailed();
    error NFREngine__BreaksHealthFactor(uint256 healthFactor);
    error NFREngine__MintFailed();
    error NFR__HealthFactorOk();
    error NFREngine__HealthFactorNotImproved();

    /** @dev Libraries */
    using OracleLib for AggregatorV3Interface;

    /** @dev Events */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemFrom, address indexed redeemTo, address token, uint256 amount); // if redeemFrom != redeemedTo, then it was liquidated

    /** @dev State Variables */
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // This means you need to be 200% over-collateralized
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant FEED_PRECISION = 1e8;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;

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
    ) public moreThanZero(collateralAmount) isAllowedToken(collateralTokenAddress) nonReentrant {
        s_collateralDeposited[msg.sender][collateralTokenAddress] += collateralAmount;

        emit CollateralDeposited(msg.sender, collateralTokenAddress, collateralAmount);

        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), collateralAmount);
        if (!success) revert NFREngine__TransferFailed();
    }

    /**
     * @notice This function will deposit your collateral and mint NFR in one transaction.
     * @param collateralTokenAddress: The ERC20 token address of the collateral you're depositing.
     * @param collateralAmount: The amount of collateral you're depositing.
     * @param amountNfrToMint: The amount of NFR you want to mint.
     */
    function depositCollateralAndMintNFR(address collateralTokenAddress, uint256 collateralAmount, uint256 amountNfrToMint) external {
        depositCollateral(collateralTokenAddress, collateralAmount);
        mintNFR(amountNfrToMint);
    }

    /**
     * @notice This function will redeem your collateral. If you have NFR minted, you will not be able to redeem until you burn your NFR.
     * @param collateralTokenAddress: The ERC20 token address of the collateral you're depositing.
     * @param collateralAmount: The amount of collateral you're depositing.
     */
    function redeemCollateral(address collateralTokenAddress, uint256 collateralAmount) public moreThanZero(collateralAmount) nonReentrant {
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice This function will withdraw your collateral and burn NFR in one transaction.
     * @param collateralTokenAddress: The ERC20 token address of the collateral you're depositing.
     * @param collateralAmount: The amount of collateral you're depositing.
     * @param amountNfrToBurn: The amount of NFR you want to mint.
     */
    function redeemCollateralForNFR(address collateralTokenAddress, uint256 collateralAmount, uint256 amountNfrToBurn) external moreThanZero(collateralAmount) {
        _burnNFR(amountNfrToBurn, msg.sender, msg.sender);
        _redeemCollateral(collateralTokenAddress, collateralAmount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Following CEI (Checks, Effects, Interactions).
     * @param amountNfrToMint The amount of decentralized stablecoin to mint.
     * @dev Must have more collateral value than the minimum threshold.
     */
    function mintNFR(uint256 amountNfrToMint) public moreThanZero(amountNfrToMint) nonReentrant {
        s_NFRMinted[msg.sender] += amountNfrToMint;
        revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_nfr.mint(msg.sender, amountNfrToMint);
        if (!minted) revert NFREngine__MintFailed();
    }

    function burnNFR(uint256 amount) external moreThanZero(amount) {
        _burnNFR(amount, msg.sender, msg.sender);
        revertIfHealthFactorIsBroken(msg.sender); // This will probably never hit...
    }

    /**
     * @notice This function will partially liquidate user.
     * @notice Caller of this function will get a 10% LIQUIDATION_BONUS for taking the users funds.
     * @notice This function working assumes that the protocol will be roughly 150% overcollateralized in order for this to work.
     * @notice A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     * @param collateral: The ERC20 token address of the collateral to liquidate to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your NFR to pay off their debt, but you don't pay off your own.
     * @param user: Address of user being liquidated, the user who is insolvent (one who has broken health factor).
     * @param debtToCover: The amount of NFR you want to burn to improve the users health factor.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) external moreThanZero(debtToCover) nonReentrant {
        uint256 startingUserHealthFactor = _healthFactor(user);

        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) revert NFR__HealthFactorOk();

        // If covering 100 NFR, we need to $100 of collateral
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // And give them a 10% bonus
        // So we are giving the liquidator $110 of WETH for 100 NFR
        // We should implement a feature to liquidate in the event the protocol is insolvent
        // And sweep extra amounts into a treasury
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // Burn NFR equal to debtToCover
        // Figure out how much collateral to recover based on how much burnt
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnNFR(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        // This conditional should never hit, but just in case
        if (endingUserHealthFactor <= startingUserHealthFactor) revert NFREngine__HealthFactorNotImproved();

        revertIfHealthFactorIsBroken(msg.sender);
    }

    function getHealthFactor() external view {}

    /** @dev Private Functions */
    function _redeemCollateral(address collateralTokenAddress, uint256 collateralAmount, address from, address to) private {
        s_collateralDeposited[from][collateralTokenAddress] -= collateralAmount;

        emit CollateralRedeemed(from, to, collateralTokenAddress, collateralAmount);

        bool success = IERC20(collateralTokenAddress).transfer(to, collateralAmount);
        if (!success) revert NFREngine__TransferFailed();
    }

    function _burnNFR(uint256 amountNfrToBurn, address onBehalfOf, address dscFrom) private {
        s_NFRMinted[onBehalfOf] -= amountNfrToBurn;

        bool success = i_nfr.transferFrom(dscFrom, address(this), amountNfrToBurn);

        // This conditional is hypothetically unreachable
        if (!success) revert NFREngine__TransferFailed();
        i_nfr.burn(amountNfrToBurn);
    }

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

    /** @dev Internal Functions */
    /**
     * @notice Check health factor (If user have enough collateral) If not -> Revert.
     * @param user Address of user to be checked.
     */
    function revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) revert NFREngine__BreaksHealthFactor(userHealthFactor);
    }

    /** @dev Public Functions */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price, , , ) = priceFeed.staleCheckLatestRoundData();
        // $100e18 USD Debt
        // 1 ETH = 2000 USD
        // The returned value from Chainlink will be 2000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        return ((usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION));
    }

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
