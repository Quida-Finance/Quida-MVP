// SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./IWitnetPriceFeed.sol";    

error TransferFailed();
error TokenNotAllowed(address token);
error NeedsMoreThanZero();

contract QuidaLending is ReentrancyGuard, Ownable {
    mapping(address => address) public PriceFeedAddress;
    mapping(address => int256) public lastValue;

    address[] public s_allowedTokens;
    // Account -> Token -> Amount
    mapping(address => mapping(address => uint256)) public s_accountToTokenDeposits;
    // Account -> Token -> Amount
    mapping(address => mapping(address => uint256)) public s_accountToTokenBorrows;

    // 5% Liquidation Reward
    uint256 public constant LIQUIDATION_REWARD = 5;
    // At 80% Loan to Value Ratio, the loan can be liquidated
    uint256 public constant LIQUIDATION_THRESHOLD = 80;
    uint256 public constant MIN_HEALH_FACTOR = 1e18;

    event AllowedTokenSet(address indexed token, address indexed priceFeed);
    event Deposit(address indexed account, address indexed token, uint256 indexed amount);
    event Borrow(address indexed account, address indexed token, uint256 indexed amount);
    event Withdraw(address indexed account, address indexed token, uint256 indexed amount);
    event Repay(address indexed account, address indexed token, uint256 indexed amount);
    event Liquidate(
        address indexed account,
        address indexed repayToken,
        address indexed rewardToken,
        uint256 halfDebtInUSD,
        address liquidator
    );      

    function deposit(address token, uint256 amount)
        external
        nonReentrant
        isAllowedToken(token)
        moreThanZero(amount)
    {
        emit Deposit(msg.sender, token, amount);
        s_accountToTokenDeposits[msg.sender][token] += amount;
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
    }

    function withdraw(address token, uint256 amount) external nonReentrant moreThanZero(amount) {
        require(s_accountToTokenDeposits[msg.sender][token] >= amount, "Not enough funds");
        emit Withdraw(msg.sender, token, amount);
        _pullFunds(msg.sender, token, amount);
        require(healthFactor(msg.sender) >= MIN_HEALH_FACTOR, "Platform will go insolvent!");
    }

    function _pullFunds(
        address account,
        address token,
        uint256 amount
    ) private {
        require(s_accountToTokenDeposits[account][token] >= amount, "Not enough funds to withdraw");
        s_accountToTokenDeposits[account][token] -= amount;
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
    }

    function borrow(address token, uint256 amount)
        external
        nonReentrant
        isAllowedToken(token)
        moreThanZero(amount)
    {
        require(IERC20(token).balanceOf(address(this)) >= amount, "Not enough tokens to borrow");
        s_accountToTokenBorrows[msg.sender][token] += amount;
        emit Borrow(msg.sender, token, amount);
        bool success = IERC20(token).transfer(msg.sender, amount);
        if (!success) revert TransferFailed();
        require(healthFactor(msg.sender) >= MIN_HEALH_FACTOR, "Platform will go insolvent!");
    }

    function liquidate(
        address account,
        address repayToken,
        address rewardToken
    ) external nonReentrant {
        require(healthFactor(account) < MIN_HEALH_FACTOR, "Account can't be liquidated!");
        uint256 halfDebt = s_accountToTokenBorrows[account][repayToken] / 2;
        uint256 halfDebtInUSD = getUSDValue(repayToken, halfDebt);
        require(halfDebtInUSD > 0, "Choose a different repayToken!");
        uint256 rewardAmountInUSD = (halfDebtInUSD * LIQUIDATION_REWARD) / 100;
        uint256 totalRewardAmountInRewardToken = getTokenValueFromUSD(
            rewardToken,
            rewardAmountInUSD + halfDebtInUSD
        );
        emit Liquidate(account, repayToken, rewardToken, halfDebtInUSD, msg.sender);
        _repay(account, repayToken, halfDebt);
        _pullFunds(account, rewardToken, totalRewardAmountInRewardToken);
    }

    function repay(address token, uint256 amount)
        external
        nonReentrant
        isAllowedToken(token)
        moreThanZero(amount)
    {
        emit Repay(msg.sender, token, amount);
        _repay(msg.sender, token, amount);
    }

    function _repay(
        address account,
        address token,
        uint256 amount
    ) private {
        // require(s_accountToTokenBorrows[account][token] - amount >= 0, "Repayed too much!");
        // On 0.8+ of solidity, it auto reverts math that would drop below 0 for a uint256
        s_accountToTokenBorrows[account][token] -= amount;
        bool success = IERC20(token).transferFrom(msg.sender, address(this), amount);
        if (!success) revert TransferFailed();
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 borrowedValueInUSD, uint256 collateralValueInUSD)
    {
        borrowedValueInUSD = getAccountBorrowedValue(user);
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    function getAccountCollateralValue(address user) public view returns (uint256) {
        uint256 totalCollateralValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenDeposits[user][token];
            uint256 valueInUSD = getUSDValue(token, amount);
            totalCollateralValueInUSD += valueInUSD;
        }
        return totalCollateralValueInUSD;
    }

    function getAccountBorrowedValue(address user) public view returns (uint256) {
        uint256 totalBorrowsValueInUSD = 0;
        for (uint256 index = 0; index < s_allowedTokens.length; index++) {
            address token = s_allowedTokens[index];
            uint256 amount = s_accountToTokenBorrows[user][token];
            uint256 valueInUSD = getUSDValue(token, amount);
            totalBorrowsValueInUSD += valueInUSD;
        }
        return totalBorrowsValueInUSD;
    }

    function getUSDValue(address token, uint256 amount) public view returns (uint256) {
        IWitnetPriceFeed PriceFeed;
        address pair = PriceFeedAddress[token];
        int256 _lastPrice;
        PriceFeed = IWitnetPriceFeed(pair);
        _lastPrice = PriceFeed.lastPrice();
        return (uint256(_lastPrice) * amount) / 1e24;
    }

    function getTokenValueFromUSD(address token, uint256 amountinusd) public view returns (uint256) {
        IWitnetPriceFeed PriceFeed;
        address pair = PriceFeedAddress[token];
        int256 price;
        PriceFeed = IWitnetPriceFeed(pair);
        price = PriceFeed.lastPrice();
        return (amountinusd * 1e18) / (uint256(price)/1e6);
    }

    function healthFactor(address account) public view returns (uint256) {
        (uint256 borrowedValueInUSD, uint256 collateralValueInUSD) = getAccountInformation(account);
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) /
            100;
        if (borrowedValueInUSD == 0) return 100e18;
        return (collateralAdjustedForThreshold * 1e18) / borrowedValueInUSD;
    }

    /********************/
    /* Modifiers */
    /********************/

    modifier isAllowedToken(address token) {
        if (PriceFeedAddress[token] == address(0)) revert TokenNotAllowed(token);
        _;
    }

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert NeedsMoreThanZero();
        }
        _;
    }

    /********************/
    /* DAO / OnlyOwner Functions */
    /********************/
    function setAllowedToken(address token, address priceFeed) external onlyOwner {
        bool foundToken = false;
        uint256 allowedTokensLength = s_allowedTokens.length;
        for (uint256 index = 0; index < allowedTokensLength; index++) {
            if (s_allowedTokens[index] == token) {
                foundToken = true;
                break;
            }
        }
        if (!foundToken) {
            s_allowedTokens.push(token);
        }
        PriceFeedAddress[token] = priceFeed;
        emit AllowedTokenSet(token, priceFeed);
    }
   
}