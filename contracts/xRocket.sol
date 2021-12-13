// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import "./library/UniswapV2/IUniswapV2Router02.sol";
import "./library/UniswapV2/IUniswapV2Factory.sol";
import "./library/MinterRole/MinterRole.sol";

import "./DividendTracker.sol";

contract xRocket is ERC20, Ownable, MinterRole {
    using SafeMath for uint256;

    IUniswapV2Router02 public uniswapV2Router;
    
    uint256 public maxSupplyAmount;

    address public treasuryWallet;
    address public burnWallet;
    address public liquidityPair;

    uint256 public baseRatio;

    uint256 public treasuryFee;
    uint256 public burnFee;
    uint256 public dividendFee;
    uint256 public liquidityFee;
    
    uint256 public totalFee;

    uint256 public sellLimit;
    uint256 public swapTokensAtAmount;

    uint256 public gasForProcessing;

    bool private tradingOpened;
    bool private pausedContract;
    bool private swapping;

    DividendTracker public dividendTracker;

    address public presaleAddress;

    mapping (address => bool) private _isExcludedFromFees;
    mapping (address => bool) private canTransferBeforeTradingIsEnabled;
    mapping (address => bool) public automatedMarketMakerPairs;
    mapping(address => bool) public _isBot;

    event UpdateDividendTracker(address indexed newAddress, address indexed oldAddress);
    event UpdateUniswapV2Router(address indexed newAddress, address indexed oldAddress);

    event ExcludeFromFees(address indexed account, bool isExcluded);
    event ExcludeMultipleAccountsFromFees(address[] accounts, bool isExcluded);

    event SetAutomatedMarketMakerPair(address indexed pair, bool indexed value);
    event TreasuryWalletUpdated(address indexed newLiquidityWallet, address indexed oldLiquidityWallet);
    event GasForProcessingUpdated(uint256 indexed newValue, uint256 indexed oldValue);
    event FixedSaleBuy(address indexed account, uint256 indexed amount, bool indexed earlyParticipant, uint256 numberOfBuyers);
    
    event SendToBurnWallet(uint256 ethReceived);
    event SendToTreasuryWallet(uint256 ethReceived);
    event SendDividends(uint256 ethReceived);
    event SwapAndLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 tokensIntoLiqudity);

    event ProcessedDividendTracker(uint256 iterations, uint256 claims, uint256 lastProcessedIndex, bool indexed automatic, uint256 gas, address indexed processor);

    constructor() ERC20("xRocket", "XROC") {
        maxSupplyAmount = 384000000 * (10**18);

        treasuryWallet = address(0x307C64146D9274597ce66A6aC1A3394619315e81);
        burnWallet = address(0x69D39e9D24f1abC49306CF69c987Eff6dA721304);

        baseRatio = 100;

        treasuryFee = 100;
        burnFee = 300;
        dividendFee = 200;
        liquidityFee = 100;
    
        totalFee = treasuryFee.add(burnFee).add(dividendFee).add(liquidityFee);

        sellLimit = 200000 * (10**18);
        swapTokensAtAmount = 10000 * (10**18);
    
        gasForProcessing = 300000;

        uniswapV2Router = IUniswapV2Router02(0x1Ed675D5e63314B760162A3D1Cae1803DCFC87C7);
        liquidityPair = IUniswapV2Factory(uniswapV2Router.factory()).createPair(address(this), uniswapV2Router.WETH());
        automatedMarketMakerPairs[liquidityPair] = true;
        
        dividendTracker = new DividendTracker();
        dividendTracker.excludeFromDividends(address(dividendTracker));
        dividendTracker.excludeFromDividends(address(this));
        dividendTracker.excludeFromDividends(msg.sender);
        dividendTracker.excludeFromDividends(address(liquidityPair));
        dividendTracker.excludeFromDividends(address(0x000000000000000000000000000000000000dEaD));
        dividendTracker.excludeFromDividends(address(0x0000000000000000000000000000000000000000));
        
        presaleAddress = address(0);

        excludeFromFees(msg.sender, true);
        excludeFromFees(address(this), true);
        excludeFromFees(treasuryWallet, true);

        canTransferBeforeTradingIsEnabled[msg.sender] = true;
        canTransferBeforeTradingIsEnabled[treasuryWallet] = true;
        
        tradingOpened = false;
        pausedContract = false;
        
        _mint(treasuryWallet, 40000000 * (10**18));
    }

    receive() external payable {}
    
    function setFees(uint256 _baseRatio, uint256 _treasuryFee, uint256 _burnFee, uint256 _dividendFee, uint256 _liquidityFee) external onlyOwner {
        baseRatio = _baseRatio;
        
        treasuryFee = _treasuryFee;
        burnFee = _burnFee;
        dividendFee = _dividendFee;
        liquidityFee = _liquidityFee;
        
        totalFee = treasuryFee.add(burnFee).add(dividendFee).add(liquidityFee);
    }
     
    function setTreasuryWallet(address _treasuryWallet) external onlyOwner {
        require(_treasuryWallet != treasuryWallet, "xRocket: The liquidity wallet is already this address");
        excludeFromFees(_treasuryWallet, true);
        emit TreasuryWalletUpdated(_treasuryWallet, treasuryWallet);
        treasuryWallet = _treasuryWallet;
    }

    function setBurnWallet(address _burnWallet) external onlyOwner {
        burnWallet = _burnWallet;
    }

    function setSellLimit(uint256 _sellLimit) external onlyOwner {
        sellLimit = _sellLimit;
    }

    function setSwapTokensAtAmount(uint256 _swapTokensAtAmount) external onlyOwner {
        swapTokensAtAmount = _swapTokensAtAmount;
    }

    function updateDividendTracker(address newAddress) public onlyOwner {
        require(newAddress != address(dividendTracker), "xRocket: The dividend tracker already has that address");

        DividendTracker newDividendTracker = DividendTracker(payable(newAddress));

        require(newDividendTracker.owner() == address(this), "xRocket: The new dividend tracker must be owned by the xRocket token contract");

        newDividendTracker.excludeFromDividends(address(newDividendTracker));
        newDividendTracker.excludeFromDividends(address(this));
        newDividendTracker.excludeFromDividends(owner());
        newDividendTracker.excludeFromDividends(address(uniswapV2Router));

        emit UpdateDividendTracker(newAddress, address(dividendTracker));

        dividendTracker = newDividendTracker;
    }

    function updateGasForProcessing(uint256 _gasForProcessing) public onlyOwner {
        require(_gasForProcessing >= 200000 && _gasForProcessing <= 500000, "xRocket: gasForProcessing must be between 200,000 and 500,000");
        require(_gasForProcessing != gasForProcessing, "xRocket: Cannot update gasForProcessing to same value");
        emit GasForProcessingUpdated(_gasForProcessing, gasForProcessing);
        gasForProcessing = _gasForProcessing;
    }

    function updateClaimWait(uint256 claimWait) external onlyOwner {
        dividendTracker.updateClaimWait(claimWait);
    }
    
    function getTradingIsOpened() public view returns (bool) {
        return tradingOpened;
    }

    function setTradingOpen(bool _isOpen) external onlyOwner {
        tradingOpened = _isOpen;
    }

    function getContractPausedStatus() public view returns (bool) {
        return pausedContract;
    }
    
    function setContractPausedStatus(bool _pausedContract) external onlyOwner {
        pausedContract = _pausedContract;
    }

    function whitelistDxSale(address _presaleAddress, address _routerAddress) public onlyOwner {
        presaleAddress = _presaleAddress;
        canTransferBeforeTradingIsEnabled[presaleAddress] = true;
        dividendTracker.excludeFromDividends(_presaleAddress);
        excludeFromFees(_presaleAddress, true);

        canTransferBeforeTradingIsEnabled[_routerAddress] = true;
        dividendTracker.excludeFromDividends(_routerAddress);
        excludeFromFees(_routerAddress, true);
    }

    function whitelistAddress(address _address, bool _enable) public onlyOwner {
        canTransferBeforeTradingIsEnabled[_address] = _enable;
    }

    function excludeDividend(address _address) public onlyOwner {
        dividendTracker.excludeFromDividends(_address);
    }

    function isExcludedFromFees(address account) public view returns(bool) {
        return _isExcludedFromFees[account];
    }

    function excludeFromFees(address account, bool excluded) public onlyOwner {
        require(_isExcludedFromFees[account] != excluded, "xRocket: Account is already the value of 'excluded'");
        _isExcludedFromFees[account] = excluded;

        emit ExcludeFromFees(account, excluded);
    }
    
    function setAntiBotslist(address[] calldata addresses, bool status) external onlyOwner {
        for (uint256 i; i < addresses.length; ++i) {
            _isBot[addresses[i]] = status;
        }
    }

    function _setAutomatedMarketMakerPair(address _liquidityPair, bool value) private {
        require(automatedMarketMakerPairs[_liquidityPair] != value, "xRocket: Automated market maker pair is already set to that value");
        automatedMarketMakerPairs[_liquidityPair] = value;

        if(value) {
            dividendTracker.excludeFromDividends(_liquidityPair);
        }

        emit SetAutomatedMarketMakerPair(_liquidityPair, value);
    }

    function processDividendTracker(uint256 gas) external {
        (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) = dividendTracker.process(gas);
        emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, false, gas, tx.origin);
    }

    function claim() external {
        dividendTracker.processAccount(payable(msg.sender), false);
    }

    function mint(address _to, uint256 _amount) public onlyMinter {
        uint256 totalSupply = totalSupply();
        require(totalSupply.add(_amount) <= maxSupplyAmount, "xRocket: Over max supply amount");
        
        _mint(_to, _amount);
    }
    
    function _transfer(address from, address to, uint256 amount) internal override {
        require(!pausedContract || from == owner() || to == owner(), "ERC20: Transfers are paused");
        require(from != address(0), "ERC20: transfer from the zero address");
        require(to != address(0), "ERC20: transfer to the zero address");
        require(!_isBot[from] && !_isBot[to], "Error: NTAM8L0K1 Try again later");
        require(tradingOpened || canTransferBeforeTradingIsEnabled[from], "xRocket: This account cannot send tokens until trading is enabled");

        if(amount == 0) {
            super._transfer(from, to, 0);
            return;
        }

        if(tradingOpened && !swapping &&
            from != owner() && from != address(uniswapV2Router) && from != address(this) &&
            automatedMarketMakerPairs[to] && !_isExcludedFromFees[to]) {
            uint256 totalSupply = totalSupply();
            sellLimit = totalSupply.div(200);

            require(amount <= sellLimit, "Sell transfer amount exceeds the sell limit.");
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        bool overLimit = contractTokenBalance >= swapTokensAtAmount;

        if(tradingOpened && !swapping && overLimit &&
           !automatedMarketMakerPairs[from] &&
           from != treasuryWallet && to != treasuryWallet) {
            swapping = true;

            uint256 burnTokens = contractTokenBalance.mul(burnFee).div(totalFee);
            uint256 treasuryTokens = contractTokenBalance.mul(treasuryFee).div(totalFee);
            uint256 lpTokens = contractTokenBalance.mul(liquidityFee).div(totalFee);
            uint256 dividendTokens = contractTokenBalance.sub(treasuryTokens).sub(burnTokens).sub(lpTokens);

            uint256 swapTokens = treasuryTokens.add(dividendTokens).add(lpTokens.div(2));
            uint256 initialBalance = address(this).balance;

            swapTokensForEth(swapTokens); 

            uint256 calcAmount = address(this).balance.sub(initialBalance);

            sendToBurnWallet(burnTokens);
            sendToTreasuryWallet(calcAmount.mul(treasuryTokens).div(swapTokens));
            swapAndLiquify(calcAmount.mul(lpTokens).div(2).div(swapTokens), lpTokens.div(2));
            sendDividends(calcAmount.mul(dividendTokens).div(swapTokens));
            
            swapping = false;
        }

        bool takeFee = tradingOpened && !swapping;

        if(_isExcludedFromFees[from] || _isExcludedFromFees[to]) {
            takeFee = false;
        }

        if(takeFee) {
            uint256 fees = amount.mul(totalFee).div(baseRatio).div(100);
            super._transfer(from, address(this), fees);
            
            amount = amount.sub(fees);
        }

        super._transfer(from, to, amount);

        try dividendTracker.setBalance(payable(from), balanceOf(from)) {} catch {}
        try dividendTracker.setBalance(payable(to), balanceOf(to)) {} catch {}

        if(!swapping) {
            uint256 gas = gasForProcessing;
            try dividendTracker.process(gas) returns (uint256 iterations, uint256 claims, uint256 lastProcessedIndex) {
                emit ProcessedDividendTracker(iterations, claims, lastProcessedIndex, true, gas, tx.origin);
            } catch {}
        }
    }

    function swapTokensForEth(uint256 tokenAmount) private {
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = uniswapV2Router.WETH();

        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount,
            0,
            path,
            address(this),
            block.timestamp
        );
        
    }

    function sendToBurnWallet(uint256 tokens) private {
        super._transfer(address(this), burnWallet, tokens);
        emit SendToBurnWallet(tokens);
    }

    function sendToTreasuryWallet(uint256 amount) private {
        payable(treasuryWallet).transfer(amount);
        emit SendToTreasuryWallet(amount);
    }

    function swapAndLiquify(uint256 amount, uint256 tokens) private {
        addLiquidity(tokens, amount);
        emit SwapAndLiquify(tokens, amount, tokens);
    }

    function addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(uniswapV2Router), tokenAmount);

        uniswapV2Router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            treasuryWallet,
            block.timestamp
        );
        
    }

    function sendDividends(uint256 amount) private {
        dividendTracker.distributeDividends{value: amount}();
        emit SendDividends(amount);
    }
    
    function recoverContractBNB(uint256 recoverRate) public onlyOwner{
        uint256 bnbAmount = address(this).balance;
        if(bnbAmount > 0){
            uint256 amount = bnbAmount.mul(recoverRate).div(100);         
            payable(treasuryWallet).transfer(amount);
        }
    }

    function recoverContractToken(address token, uint256 recoverRate) public onlyOwner{
        uint256 tokenBalance = IERC20(token).balanceOf(address(this));
        if(tokenBalance > 0){
            uint256 amount = tokenBalance.mul(recoverRate).div(100);            
            IERC20(token).transfer(treasuryWallet, amount);
        }
    }
}