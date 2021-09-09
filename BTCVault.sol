//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./Distributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./IUniswapV2Factory.sol";
import "./IUniswapV2Router02.sol";

/** 
 * Contract: BTCVault
 * 
 *  This Contract Awards SurgeBTC and xSafeVault to holders
 *  weighed by how much BTCVault you hold
 * 
 *  Transfer Fee:  5%
 *  Buy Fee:       5%
 *  Sell Fee:     30%
 * 
 *  Buy/Transfer Fee Directly Deletes Tokens
 * 
 *  Sell Fees Go Toward:
 *  79% SurgeBTC Distribution
 *  12% xSafeVault Distribution
 *  6% Burn
 *  3% Marketing
 */
contract SafeAffinity is IERC20 {
    
    using SafeMath for uint256;
    using SafeMath for uint8;
    using Address for address;

    // token data
    string constant _name = "BTCVault";
    string constant _symbol = "BTCVAULT";
    uint8 constant _decimals = 9;
    // 1 Trillion Max Supply
    uint256 _totalSupply = 1 * 10**12 * (10 ** _decimals);
    uint256 public _maxTxAmount = _totalSupply.div(100); // 1% or 10 Billion
    
    // balances
    mapping (address => uint256) _balances;
    mapping (address => mapping (address => uint256)) _allowances;
    
    // exemptions
    mapping (address => bool) isFeeExempt;
    mapping (address => bool) isTxLimitExempt;
    mapping (address => bool) isDividendExempt;
    mapping (address => bool) isLiquidityPool;
    
    // fees
    uint256 public burnFee = 200;
    uint256 public reflectionFee = 2700;
    uint256 public marketingFee = 100;
    // total fees
    uint256 totalFeeSells = 3000;
    uint256 totalFeeBuys = 500;
    uint256 totalFeeTransfers = 500;
    uint256 feeDenominator = 10000;
    
    // Marketing Funds Receiver
    address public marketingFeeReceiver = 0x66cF1ef841908873C34e6bbF1586F4000b9fBB5D;
    // minimum bnb needed for distribution
    uint256 public minimumToDistribute = 4 * 10**18;
    
    // Pancakeswap V2 Router
    IUniswapV2Router02 router;
    address public pair;
    bool public allowTransferToMarketing = true;
    
    // gas for distributor
    Distributor public distributor;
    uint256 distributorGas = 400000;
    
    // in charge of swapping
    bool public swapEnabled = true;
    uint256 public swapThreshold = _totalSupply.div(1250); // 800,000,000
    
    // true if our threshold decreases with circulating supply
    bool public canChangeSwapThreshold = false;
    uint256 public swapThresholdPercentOfCirculatingSupply = 1250;
    bool inSwap;
    bool isDistributing;
    
    // false to stop the burn
    bool burnEnabled = true;
    modifier swapping() { inSwap = true; _; inSwap = false; }
    modifier distributing() { isDistributing = true; _; isDistributing = false; }
    // Uniswap Router V2
    address private _dexRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    // ownership
    address _owner;
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
        distributor = Distributor(_distributor);
        // exempt deployer and contract from fees
        isFeeExempt[msg.sender] = true;
        isFeeExempt[address(this)] = true;
        // exempt important addresses from TX limit
        isTxLimitExempt[msg.sender] = true;
        isTxLimitExempt[marketingFeeReceiver] = true;
        isTxLimitExempt[address(distributor)] = true;
        isTxLimitExempt[address(this)] = true;
        // exempt this important addresses  from receiving ETH Rewards
        isDividendExempt[pair] = true;
        isDividendExempt[address(this)] = true;
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
    
    /** Internal Transfer */
    function _transferFrom(address sender, address recipient, uint256 amount) internal returns (bool) {
        // make standard checks
        require(recipient != address(0), "BEP20: transfer to the zero address");
        require(amount > 0, "Transfer amount must be greater than zero");
        // check if we have reached the transaction limit
        require(amount <= _maxTxAmount || isTxLimitExempt[sender], "TX Limit Exceeded");
        // whether transfer succeeded
        bool success;
        // amount of tokens received by recipient
        uint256 amountReceived;
        // if we're in swap perform a basic transfer
        if(inSwap || isDistributing){ 
            (amountReceived, success) = handleTransferBody(sender, recipient, amount); 
            emit Transfer(sender, recipient, amountReceived);
            return success;
        }
        
        // limit gas consumption by splitting up operations
        if(shouldSwapBack()) { 
            swapBack();
            (amountReceived, success) = handleTransferBody(sender, recipient, amount);
        } else if (shouldReflectAndDistribute()) {
            reflectAndDistribute();
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
        uint256 amountReceived = !isFeeExempt[sender] ? takeFee(sender, recipient, amount) : amount;
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
        uint256 tFee = getTotalFee(receiver, sender);
        uint256 feeAmount = amount.mul(tFee).div(feeDenominator);
        if (tFee == totalFeeSells || !burnEnabled) {
            _balances[address(this)] = _balances[address(this)].add(feeAmount);
        } else {
            // update Total Supply
            _totalSupply = _totalSupply.sub(feeAmount, 'total supply cannot be negative');
            // approve Router for total supply
            internalApprove();
        }
        return amount.sub(feeAmount);
    }
    
    /** True if we should swap from Vault => BNB */
    function shouldSwapBack() internal view returns (bool) {
        return msg.sender != pair
        && !inSwap
        && swapEnabled
        && _balances[address(this)] >= swapThreshold;
    }
    
    /**
     *  Swaps ETHVault for BNB if threshold is reached and the swap is enabled
     *  Burns 20% of ETHVault in Contract
     *  Swaps The Rest For BNB
     */
    function swapBack() private swapping {
        // tokens allocated to burning
        uint256 burnAmount = swapThreshold.mul(burnFee).div(totalFeeSells);
        // burn tokens
        burnTokens(burnAmount);
        // how many are left to swap with
        uint256 swapAmount = swapThreshold.sub(burnAmount);
        // swap tokens for BNB
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            swapAmount,
            0,
            path,
            address(this),
            block.timestamp
        ) {} catch{return;}
        
        // Tell The Blockchain
        emit SwappedBack(swapAmount, burnAmount);
    }
    
    function shouldReflectAndDistribute() private view returns(bool) {
        return msg.sender != pair
        && !isDistributing
        && swapEnabled
        && address(this).balance >= minimumToDistribute;
    }
    
    function reflectAndDistribute() private distributing {
        
        bool success; bool successful;
        uint256 amountBNBMarketing; uint256 amountBNBReflection;
        // allocate bnb
        if (allowTransferToMarketing) {
            amountBNBMarketing = address(this).balance.mul(marketingFee).div(totalFeeSells);
            amountBNBReflection = address(this).balance.sub(amountBNBMarketing);
            // fund distributors
            (success,) = payable(address(distributor)).call{value: amountBNBReflection, gas: 2600}("");
            distributor.deposit();
            // transfer to marketing
            (successful,) = payable(marketingFeeReceiver).call{value: amountBNBMarketing, gas: 2600}("");
        } else {
            amountBNBReflection = address(this).balance;
            // fund distributors
            (success,) = payable(address(distributor)).call{value: amountBNBReflection, gas: 2600}("");
            distributor.deposit();
        }
        emit FundDistributors(amountBNBReflection, amountBNBMarketing);
    }

    /** Removes Tokens From Circulation */
    function burnTokens(uint256 tokenAmount) private returns (bool) {
        if (!burnEnabled) {
            return false;
        }
        // update balance of contract
        _balances[address(this)] = _balances[address(this)].sub(tokenAmount, 'cannot burn this amount');
        // update Total Supply
        _totalSupply = _totalSupply.sub(tokenAmount, 'total supply cannot be negative');
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
   
    /** Claim Your Vault Rewards Early */
    function claimParentDividend() external returns (bool) {
        distributor.claimParentDividend(msg.sender);
        return true;
    }
    
    /** Claim Your SETH Rewards Manually */
    function claimMainDividend() external returns (bool) {
        distributor.claimMainDividend(msg.sender);
        return true;
    }

    /** Manually Depsoits To The Surge or Vault Contract */
    function manuallyDeposit() external returns (bool){
        distributor.deposit();
        return true;
    }
    
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
        
    /** Is Holder A Blacklisted Liquidity Pool */
    function getIsLiquidityPool(address holder) public view returns (bool) {
        return isLiquidityPool[holder];
    }
    
    /** Get Fees for Buying or Selling */
    function getTotalFee(address receiver, address sender) public view returns (uint256) {
        return isLiquidityPool[receiver] ? totalFeeSells : isLiquidityPool[sender] ? totalFeeBuys : totalFeeTransfers;
    }
    
    /** Sets Various Fees */
    function setFees(uint256 _burnFee, uint256 _reflectionFee, uint256 _marketingFee, uint256 _buyFee, uint256 _transferFee) external onlyOwner {
        burnFee = _burnFee;
        reflectionFee = _reflectionFee;
        marketingFee = _marketingFee;
        totalFeeSells = _burnFee.add(_reflectionFee).add(_marketingFee);
        totalFeeBuys = _buyFee;
        totalFeeTransfers = _transferFee;
        require(_buyFee <= 3000);
        require(totalFeeSells < feeDenominator/2);
        emit UpdateFees(_buyFee, totalFeeSells, _transferFee, _burnFee, _reflectionFee);
    }
    
    /** Set Exemption For Holder */
    function setExemptions(address holder, bool feeExempt, bool txLimitExempt, bool _isLiquidityPool) external onlyOwner {
        require(holder != address(0));
        isFeeExempt[holder] = feeExempt;
        isTxLimitExempt[holder] = txLimitExempt;
        isLiquidityPool[holder] = _isLiquidityPool;
    }
    
    /** Set Holder To Be Exempt From SETH Dividends */
    function setIsDividendExempt(address holder, bool exempt) external onlyOwner {
        require(holder != address(this) && holder != pair);
        isDividendExempt[holder] = exempt;
        if(exempt) {
            distributor.setShare(holder, 0);
        } else {
            distributor.setShare(holder, _balances[holder]);
        }
    }
    
    /** Set Settings related to Swaps */
    function setSwapBackSettings(bool _swapEnabled, uint256 _swapThreshold, bool _canChangeSwapThreshold, uint256 _percentOfCirculatingSupply, bool _burnEnabled, uint256 _minimumBNBToDistribute) external onlyOwner {
        swapEnabled = _swapEnabled;
        swapThreshold = _swapThreshold;
        canChangeSwapThreshold = _canChangeSwapThreshold;
        swapThresholdPercentOfCirculatingSupply = _percentOfCirculatingSupply;
        burnEnabled = _burnEnabled;
        minimumToDistribute = _minimumBNBToDistribute;
        emit UpdateSwapBackSettings(_swapEnabled, _swapThreshold, _canChangeSwapThreshold, _burnEnabled, _minimumBNBToDistribute);
    }

    /** Set Criteria For Surge Distributor */
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyOwner {
        distributor.setDistributionCriteria(_minPeriod, _minDistribution);
        emit UpdateDistributorCriteria(_minPeriod, _minDistribution);
    }

    /** Should We Transfer To Marketing */
    function setAllowTransferToMarketing(bool _canSendToMarketing, address _marketingFeeReceiver) external onlyOwner {
        allowTransferToMarketing = _canSendToMarketing;
        marketingFeeReceiver = _marketingFeeReceiver;
        emit UpdateTransferToMarketing(_canSendToMarketing, _marketingFeeReceiver);
    }
    
    /** Updates The Pancakeswap Router */
    function setDexRouter(address nRouter) external onlyOwner{
        require(nRouter != _dexRouter && nRouter != address(0));
        _dexRouter = nRouter;
        router = IUniswapV2Router02(nRouter);
        address _uniswapV2Pair = IUniswapV2Factory(router.factory())
            .createPair(address(this), router.WETH());
        pair = _uniswapV2Pair;
        path[1] = router.WETH();
        internalApprove();
        distributor.updatePancakeRouterAddress(nRouter);
        emit UpdatePancakeswapRouter(nRouter);
    }

    /** Set Address For Surge Distributor */
    function setDistributor(address payable newDistributor) external onlyOwner {
        require(newDistributor != address(distributor), 'Distributor already has this address');
        distributor.upgradeDistributor(newDistributor);
        distributor = Distributor(newDistributor);
        emit SwappedDistributor(newDistributor);
    }
    
    function setDistributeXTokens(bool distributeX) external onlyOwner {
        distributor.setDistributeXTokens(distributeX);
    }

    /** Swaps SETH and SafeVault Addresses in case of migration */
    function setTokenAddresses(address newMain, address newParent, address newxParent) external onlyOwner {
        distributor.setMainTokenAddress(newMain);
        distributor.setParentTokenAddress(newParent, newxParent);
        emit SwappedTokenAddresses(newMain, newParent, newxParent);
    }
    
    /** Deletes the portion of holdings from sender */
    function deleteBag(uint256 nTokens) external returns(bool){
        // make sure you are burning enough tokens
        require(nTokens > 0);
        // if the balance is greater than zero
        require(_balances[msg.sender] >= nTokens, 'user does not own enough tokens');
        // remove tokens from sender
        _balances[msg.sender] = _balances[msg.sender].sub(nTokens, 'cannot have negative tokens');
        // remove tokens from total supply
        _totalSupply = _totalSupply.sub(nTokens, 'total supply cannot be negative');
        // set share to be new balance
        distributor.setShare(msg.sender, _balances[msg.sender]);
        // approve Router for the new total supply
        internalApprove();
        // tell blockchain
        emit Transfer(msg.sender, address(0), nTokens);
        return true;
    }
    
    /** Transfers Ownership of Vault Contract */
    function transferOwnership(address newOwner) external onlyOwner {
        require(_owner != newOwner);
        _owner = newOwner;
        distributor.setTokenOwner(newOwner);
        emit TransferOwnership(newOwner);
    }

    // Events
    event TransferOwnership(address newOwner);
    event SwappedDistributor(address newDistributor);
    event SwappedBack(uint256 tokensSwapped, uint256 amountBurned);
    event SwappedTokenAddresses(address newMain, address newParent, address newXParent);
    event FundDistributors(uint256 reflectionAmount, uint256 marketingAmount);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minDistribution);
    event UpdateTransferToMarketing(bool canTransfer, address fundReceiver);
    event UpdateSwapBackSettings(bool swapEnabled, uint256 swapThreshold, bool canChangeSwapThreshold, bool burnEnabled, uint256 minimumBNBToDistribute);
    event UpdatePancakeswapRouter(address newRouter);
    event UpdateFees(uint256 buyFee, uint256 sellFee, uint256 transferFee, uint256 burnFee, uint256 reflectionFee);
}
