//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router02.sol";
import "./ReentrantGuard.sol";

/** 
 * Contract: Vault
 * 
 *  This Contract Awards SurgeBTC and xSafeVault to holders
 *  weighed by how much Vault you hold. Surge Tokens and Vault Tokens
 *  can be substituted for one another when manually claiming
 * 
 *  Transfer Fee:  5%
 *  Buy Fee:       5%
 *  Sell Fee:     30%
 * 
 *  Buys/Transfers Directly Deletes Tokens From Fees
 * 
 *  Sell Fees Go Toward:
 *  80% SurgeBTC Distribution
 *  12% xParent Distribution
 *  5% Burn
 *  3% Marketing
 */
contract BTCVault is IERC20, ReentrancyGuard {
    
    using SafeMath for uint256;
    using SafeMath for uint8;
    using Address for address;

    // token data
    string constant _name = "Vault";
    string constant _symbol = "VAULT";
    uint8 constant _decimals = 9;
    
    // 1 Trillion Max Supply
    uint256 _totalSupply = 1 * 10**12 * (10 ** _decimals);
    uint256 public _maxTxAmount = _totalSupply.div(100); // 1% or 10 Billion
    
    // balances
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;
    
    // Token Lock Structure
    struct TokenLock {
        bool isLocked;
        uint256 startTime;
        uint256 duration;
        uint256 nTokens;
    }
    
    // exemptions
    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;
    mapping (address => bool) isDividendExempt;
    mapping (address => bool) public isLiquidityPool;
    mapping (address => TokenLock) tokenLockers;
    
    // fees
    uint256 public burnFee = 150;
    uint256 public reflectionFee = 2750;
    uint256 public marketingFee = 100;
    // total fees
    uint256 totalFeeSells = 3000;
    uint256 totalFeeBuys = 500;
    uint256 totalFeeTransfers = 500;
    uint256 constant feeDenominator = 10000;
    
    // Marketing Funds Receiver
    address public marketingFeeReceiver = 0x66cF1ef841908873C34e6bbF1586F4000b9fBB5D;
    // minimum bnb needed for distribution
    uint256 public minimumToDeposit = 25 * 10**17;
    
    // Pancakeswap V2 Router
    IUniswapV2Router02 router;
    address public pair;

    // gas for distributor
    IDistributor public distributor;
    uint256 distributorGas = 400000;
    
    // in charge of swapping
    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply.div(1250); // 800,000,000 tokens
    
    // true if our threshold decreases with circulating supply
    bool public canChangeSwapThreshold = false;
    uint256 public swapThresholdPercentOfCirculatingSupply = 1250;
    bool inSwap;

    // false to stop the burn
    bool burnEnabled = true;
    modifier swapping() { inSwap = true; _; inSwap = false; }
    
    // Uniswap Router V2
    address private _dexRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    
    // ownership
    address public _owner;
    modifier onlyOwner(){require(msg.sender == _owner, 'OnlyOwner'); _;}
    
    // Token -> BNB
    address[] path;

    // initialize some stuff
    constructor ( address payable _distributor
    ) {
        // Pancakeswap V2 Router
        router = IUniswapV2Router02(_dexRouter);
        // Liquidity Pool Address for BNB -> Vault
        pair = IUniswapV2Factory(router.factory()).createPair(router.WETH(), address(this));
        _allowances[address(this)][address(router)] = _totalSupply;
        // our dividend Distributor
        distributor = IDistributor(_distributor);
        // exempt deployer and contract from fees
        isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;
        // exempt important addresses from TX limit
        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[marketingFeeReceiver] = true;
        isTxLimitExempt[address(this)] = true;
        // exempt important addresses from receiving Rewards
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
        // declare LP as Liquidity Pool
        isLiquidityPool[pair] = true;
        // approve router of total supply
        approve(_dexRouter, _totalSupply);
        approve(address(pair), _totalSupply);
        _balances[msg.sender] = _totalSupply;
        // token path
        path = new address[](2);
        path[0] = address(this);
        path[1] = router.WETH();
        _owner = msg.sender;
        emit Transfer(address(0), msg.sender, _totalSupply);
    }

    receive() external payable { }

    function totalSupply() external view override returns (uint256) { return _totalSupply; }
    function balanceOf(address account) public view override returns (uint256) { return _balances[account]; }
    function allowance(address holder, address spender) external view override returns (uint256) { return _allowances[holder][spender]; }
    function name() public pure returns (string memory) {
        return _name;
    }

    function symbol() public pure returns (string memory) {
        return _symbol;
    }

    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    function approve(address spender, uint256 amount) public override returns (bool) {
        _allowances[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }
    
    /** Approves Router and Pair For Updating Total Supply */
    function internalApprove() private {
        _allowances[address(this)][address(router)] = _totalSupply;
        _allowances[address(this)][address(pair)] = _totalSupply;
    }
    
    /** Approve Total Supply */
    function approveMax(address spender) external returns (bool) {
        return approve(spender, _totalSupply);
    }
    
    /** Transfer Function */
    function transfer(address recipient, uint256 amount) external override returns (bool) {
        return _transferFrom(msg.sender, recipient, amount);
    }
    
    /** Transfer Function */
    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        if(_allowances[sender][msg.sender] != _totalSupply){
            _allowances[sender][msg.sender] = _allowances[sender][msg.sender].sub(amount, "Insufficient Allowance");
        }

        return _transferFrom(sender, recipient, amount);
    }
    
    ////////////////////////////////////
    /////    INTERNAL FUNCTIONS    /////
    ////////////////////////////////////
    
    /** Internal Transfer */
    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        // make standard checks
        require(recipient != address(0), "BEP20: Invalid Transfer");
        require(amount > 0, "Zero Amount");
        // check if we have reached the transaction limit
        require(amount <= _maxTxAmount || isTxLimitExempt[sender], "TX Limit");
        if (tokenLockers[sender].isLocked) {
            if (tokenLockers[sender].startTime.add(tokenLockers[sender].duration) > block.number) {
                require(amount <= tokenLockers[sender].nTokens, 'Exceeds Token Lock Allowance');
                tokenLockers[sender].nTokens = tokenLockers[sender].nTokens.sub(amount);
            } else {
                delete tokenLockers[sender];
            }
        }
        // whether transfer succeeded
        bool success;
        // amount of tokens received by recipient
        uint256 amountReceived;
        // if we're in swap perform a basic transfer
        if(inSwap){
            (amountReceived, success) = handleTransferBody(sender, recipient, amount);
            emit Transfer(sender, recipient, amountReceived);
            return success;
        }
        
        // limit gas consumption by splitting up operations
        if(shouldSwapBack()) {
            swapBack();
            (amountReceived, success) = handleTransferBody(sender, recipient, amount);
        } else if (shouldDepositDistributor()) {
            distributor.deposit();
            (amountReceived, success) = handleTransferBody(sender, recipient, amount);
        } else {
            (amountReceived, success) = handleTransferBody(sender, recipient, amount);
            try distributor.process(distributorGas) {} catch {}
        }
        
        emit Transfer(sender, recipient, amountReceived);
        return success;
    }
    
    /** Takes Associated Fees and sets holders' new Share for the Safemoon Distributor */
    function handleTransferBody(address sender, address recipient, uint256 amount) internal returns (uint256, bool) {
        // subtract balance from sender
        _balances[sender] = _balances[sender].sub(amount, "Insufficient Balance");
        // amount receiver should receive
        uint256 amountReceived = (isFeeExempt[sender] || isFeeExempt[recipient]) ? amount : takeFee(sender, recipient, amount);
        // add amount to recipient
        _balances[recipient] = _balances[recipient].add(amountReceived);
        // set shares for distributors
        if(!isDividendExempt[sender]){ 
            distributor.setShare(sender, _balances[sender]);
        }
        if(!isDividendExempt[recipient]){ 
            distributor.setShare(recipient, _balances[recipient]);
        }
        // return the amount received by receiver
        return (amountReceived, true);
    }
    
    /** Takes Fee and Stores in contract Or Deletes From Circulation */
    function takeFee(address sender, address receiver, uint256 amount) internal returns (uint256) {
        uint256 tFee = isLiquidityPool[receiver] ? totalFeeSells : isLiquidityPool[sender] ? totalFeeBuys : totalFeeTransfers;
        uint256 feeAmount = amount.mul(tFee).div(feeDenominator);
        if (isLiquidityPool[receiver] || !burnEnabled) {
            _balances[address(this)] = _balances[address(this)].add(feeAmount);
        } else {
            // update Total Supply
            _totalSupply = _totalSupply.sub(feeAmount);
            // approve Router for total supply
            internalApprove();
        }
        return amount.sub(feeAmount);
    }
    
    /** True if we should swap from Vault => BNB */
    function shouldSwapBack() internal view returns (bool) {
        return !isLiquidityPool[msg.sender]
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }
    
    /**
     *  Swaps ETHVault for BNB if threshold is reached and the swap is enabled
     *  Burns 20% of ETHVault in Contract, delivers 3% to marketing
     *  Swaps The Rest For BNB
     */
    function swapBack() private swapping {
        // tokens allocated to burning
        uint256 burnAmount = swapThreshold.mul(burnFee).div(totalFeeSells);
        // burn tokens
        burnTokens(burnAmount);
        // tokens allocated to marketing
        uint256 marketingTokens = swapThreshold.mul(marketingFee).div(totalFeeSells);
        // send tokens to marketing wallet
        if (marketingTokens > 0) {
            _balances[address(this)] = _balances[address(this)].sub(marketingTokens);
            _balances[marketingFeeReceiver] = _balances[marketingFeeReceiver].add(marketingTokens);
            if (!isDividendExempt[marketingFeeReceiver]) {
                distributor.setShare(marketingFeeReceiver, _balances[marketingFeeReceiver]);
            }
            emit Transfer(address(this), marketingFeeReceiver, marketingTokens);
        }
        // how many are left to swap with
        uint256 swapAmount = swapThreshold.sub(burnAmount).sub(marketingTokens);
        // swap tokens for BNB
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            0,
            path,
            address(distributor),
            block.timestamp.add(30)
        ) {} catch{return;}
        // Tell The Blockchain
        emit SwappedBack(swapAmount, burnAmount, marketingTokens);
    }
    
    /** Should We Deposit Funds inside of Distributor */
    function shouldDepositDistributor() private view returns(bool) {
        return !isLiquidityPool[msg.sender]
        && !inSwap
        && swapEnabled
        && address(distributor).balance >= minimumToDeposit;
    }

    /** Removes Tokens From Circulation */
    function burnTokens(uint256 tokenAmount) private returns (bool) {
        if (!burnEnabled) {
            return false;
        }
        // update balance of contract
        _balances[address(this)] = _balances[address(this)].sub(tokenAmount);
        // update Total Supply
        _totalSupply = _totalSupply.sub(tokenAmount);
        // approve Router for total supply
        internalApprove();
        // change Swap Threshold if we should
        if (canChangeSwapThreshold) {
            swapThreshold = _totalSupply.div(swapThresholdPercentOfCirculatingSupply);
        }
        // emit Transfer to Blockchain
        emit Transfer(address(this), address(0), tokenAmount);
        return true;
    }
    
    
    ////////////////////////////////////
    /////    EXTERNAL FUNCTIONS    /////
    ////////////////////////////////////
    
    
    
    /** Claim Your Vault Rewards Early */
    function claimParentDividend() external nonReentrant {
        distributor.claimParentDividend(msg.sender);
    }
    
    /** Claim Your SETH Rewards Manually */
    function claimMainDividend() external nonReentrant {
        distributor.claimMainDividend(msg.sender);
    }
    
    /** Disables User From Receiving Automatic Rewards To Enable Options */
    function disableAutoRewardsForShareholder(bool autoRewardsDisabled) external nonReentrant {
        distributor.changeAutoRewardsForShareholder(msg.sender, autoRewardsDisabled);
    }
    
    /** Claim Parent Vault Token In External Token */
    function claimParentDividendInExternalToken(address xTokenDesired) external nonReentrant {
        distributor.claimxParentDividendInDesiredToken(msg.sender, xTokenDesired);
    }
    
    /** Manually Claim Surge Token Dividend in Different Surge Token */
    function claimMainDividendInExternalToken(address xTokenDesired) external nonReentrant {
        distributor.claimMainDividendInDesiredSurgeToken(msg.sender, xTokenDesired);
    }
    
    /** Deletes the portion of holdings from sender */
    function deleteBag(uint256 nTokens) external nonReentrant returns(bool){
        // make sure you are burning enough tokens
        require(nTokens > 0 && _balances[msg.sender] >= nTokens, 'Insufficient Balance');
        // remove tokens from sender
        _balances[msg.sender] = _balances[msg.sender].sub(nTokens);
        // remove tokens from total supply
        _totalSupply = _totalSupply.sub(nTokens);
        // set share to be new balance
        if (!isDividendExempt[msg.sender]) {
            distributor.setShare(msg.sender, _balances[msg.sender]);
        }
        // approve Router for the new total supply
        internalApprove();
        // tell blockchain
        emit Transfer(msg.sender, address(0), nTokens);
        return true;
    }
    
    
    
    ////////////////////////////////////
    /////      READ FUNCTIONS      /////
    ////////////////////////////////////
    
    
    
    /** Is Holder Exempt From Fees */
    function getIsFeeExempt(address holder) public view returns (bool) {
        return isFeeExempt[holder];
    }
    
    /** Is Holder Exempt From SETH Dividends */
    function getIsDividendExempt(address holder) public view returns (bool) {
        return isDividendExempt[holder];
    }
    
    /** Is Holder Exempt From Transaction Limit */
    function getIsTxLimitExempt(address holder) public view returns (bool) {
        return isTxLimitExempt[holder];
    }
    
    /** True If Tokens Are Locked For Target, False If Unlocked */
    function isTokenLocked(address target) external view returns (bool) {
        return tokenLockers[target].isLocked;
    }

    /** Time In Blocks Until Tokens Unlock For Target User */    
    function timeLeftUntilTokensUnlock(address target) public view returns (uint256) {
        if (tokenLockers[target].isLocked) {
            uint256 endTime = tokenLockers[target].startTime.add(tokenLockers[target].duration);
            if (endTime <= block.number) return 0;
            return endTime.sub(block.number);
        } else {
            return 0;
        }
    }
    
    /** Number Of Tokens A Locked Wallet Has Left To Spend Before Time Expires */
    function nTokensLeftToSpendForLockedWallet(address wallet) external view returns (uint256) {
        return tokenLockers[wallet].nTokens;
    }
    
    
    ////////////////////////////////////
    /////     OWNER FUNCTIONS      /////
    ////////////////////////////////////
    

    /** Sets Various Fees */
    function setFees(uint256 _burnFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _buyFee, uint256 _transferFee) external onlyOwner {
        burnFee = _burnFee;
        reflectionFee = _reflectionFee;
        marketingFee = _marketingFee;
        totalFeeSells = _burnFee.add(_reflectionFee).add(_marketingFee);
        totalFeeBuys = _buyFee;
        totalFeeTransfers = _transferFee;
        require(_buyFee <= feeDenominator/2);
        require(totalFeeSells <= feeDenominator/2);
        emit UpdateFees(_buyFee, totalFeeSells, _transferFee, _burnFee, _reflectionFee);
    }
    
    /** Set Exemption For Holder */
    function setExemptions(address holder, bool feeExempt, bool txLimitExempt, bool _isLiquidityPool) external onlyOwner {
        require(holder != address(0), 'Invalid Address');
        isFeeExempt[holder] = feeExempt;
        isTxLimitExempt[holder] = txLimitExempt;
        isLiquidityPool[holder] = _isLiquidityPool;
        emit SetExemptions(holder, feeExempt, txLimitExempt, _isLiquidityPool);
    }
    
    /** Set Holder To Be Exempt From SETH Dividends */
    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        isDividendExempt[holder] = exempt;
        if(exempt) {
            distributor.setShare(holder, 0);
        } else {
            distributor.setShare(holder, _balances[holder]);
        }
    }
    
    /** Set Settings related to Swaps */
    function setSwapBackSettings(bool _swapEnabled, uint256 _swapThreshold, bool _canChangeSwapThreshold, uint256 _percentOfCirculatingSupply, bool _burnEnabled, uint256 _minimumToDeposit) external onlyOwner {
        swapEnabled = _swapEnabled;
        swapThreshold = _swapThreshold;
        canChangeSwapThreshold = _canChangeSwapThreshold;
        swapThresholdPercentOfCirculatingSupply = _percentOfCirculatingSupply;
        burnEnabled = _burnEnabled;
        minimumToDeposit = _minimumToDeposit;
        emit UpdateSwapBackSettings(_swapEnabled, _swapThreshold, _canChangeSwapThreshold, _burnEnabled, _minimumToDeposit);
    }

    /** Set Criteria For Surge Distributor */
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minMainDistribution, uint256 _minParentDistribution) external onlyOwner {
        distributor.setDistributionCriteria(_minPeriod, _minMainDistribution, _minParentDistribution);
        emit UpdateDistributorCriteria(_minPeriod, _minMainDistribution, _minParentDistribution);
    }

    /** Should We Transfer To Marketing */
    function setMarketingFundReceiver(address _marketingFeeReceiver) external onlyOwner {
        require(_marketingFeeReceiver != address(0), 'Invalid Address');
        isTxLimitExempt[marketingFeeReceiver] = false;
        marketingFeeReceiver = _marketingFeeReceiver;
        isTxLimitExempt[_marketingFeeReceiver] = true;
        emit UpdateTransferToMarketing(_marketingFeeReceiver);
    }
    
    function setDistributorGas(uint256 newGas) external onlyOwner {
        require(newGas >= 10**5 && newGas <= 10**7, 'Out Of Range');
        distributorGas = newGas;
        emit UpdatedDistributorGas(newGas);
    }
    
    /** Updates The Pancakeswap Router */
    function setDexRouter(address nRouter) external onlyOwner{
        require(nRouter != _dexRouter && nRouter != address(0), 'Invalid Address');
        _dexRouter = nRouter;
        router = IUniswapV2Router02(nRouter);
        address _newPair = IUniswapV2Factory(router.factory())
            .createPair(address(this), router.WETH());
        pair = _newPair;
        isLiquidityPool[_newPair] = true;
        isDividendExempt[_newPair] = true;
        path[1] = router.WETH();
        internalApprove();
        distributor.updatePancakeRouterAddress(nRouter);
        emit UpdatePancakeswapRouter(nRouter);
    }

    /** Set Address For Surge Distributor */
    function setDistributor(address newDistributor) external onlyOwner {
        require(newDistributor != address(distributor), 'Invalid Address');
        require(newDistributor != address(0), 'Invalid Address');
        distributor.upgradeDistributor(newDistributor);
        distributor = IDistributor(payable(newDistributor));
        emit SwappedDistributor(newDistributor);
    }

    /** Swaps SETH and SafeVault Addresses in case of migration */
    function setTokenAddresses(address newMain, address newxParent) external onlyOwner {
        distributor.setMainTokenAddress(newMain);
        distributor.setParentTokenAddress(newxParent);
        emit SwappedTokenAddresses(newMain, newxParent);
    }
    
    /** Lock Tokens For A User Over A Set Amount of Time */
    function lockTokens(address target, uint256 lockDurationInBlocks, uint256 tokenAllowance) external onlyOwner {
        require(lockDurationInBlocks <= 10512000, 'Invalid Duration');
        require(timeLeftUntilTokensUnlock(target) <= 100, 'Not Time');
        tokenLockers[target] = TokenLock({
            isLocked:true,
            startTime:block.number,
            duration:lockDurationInBlocks,
            nTokens:tokenAllowance
        });
        emit TokensLockedForWallet(target, lockDurationInBlocks, tokenAllowance);
    }
    
    /** Transfers Ownership of Vault Contract */
    function transferOwnership(address newOwner) external onlyOwner {
        require(_owner != newOwner);
        _owner = newOwner;
        emit TransferOwnership(newOwner);
    }

    
    ////////////////////////////////////
    //////        EVENTS          //////
    ////////////////////////////////////
    
    
    event TransferOwnership(address newOwner);
    event UpdatedDistributorGas(uint256 newGas);
    event SwappedDistributor(address newDistributor);
    event SetExemptions(address holder, bool feeExempt, bool txLimitExempt, bool isLiquidityPool);
    event SwappedBack(uint256 tokensSwapped, uint256 amountBurned, uint256 marketingTokens);
    event SwappedTokenAddresses(address newMain, address newXParent);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minMainDistribution, uint256 minParentDistribution);
    event UpdateTransferToMarketing(address fundReceiver);
    event UpdateSwapBackSettings(bool swapEnabled, uint256 swapThreshold, bool canChangeSwapThreshold, bool burnEnabled, uint256 minimumBNBToDistribute);
    event UpdatePancakeswapRouter(address newRouter);
    event TokensLockedForWallet(address wallet, uint256 duration, uint256 allowanceToSpend);
    event UpdateFees(uint256 buyFee, uint256 sellFee, uint256 transferFee, uint256 burnFee, uint256 reflectionFee);
    
}
