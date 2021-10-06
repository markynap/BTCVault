//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IUniswapV2Router02.sol";
import "./IERC20.sol";
import "./ReentrantGuard.sol";

/** Distributes Vault Tokens and Surge Tokens To Holders Varied on Weight */
contract Distributor is IDistributor, ReentrancyGuard {
    
    using SafeMath for uint256;
    using Address for address;
    
    // Vault Contract
    address public _token;
    
    // Share of Vault
    struct Share {
        uint256 amount;
        uint256 totalExcluded;
        address rewardToken;
    }
    
    // Reward Token
    struct RewardToken {
        bool isApproved;
        address buyerAddress;
        address dexRouter;
        bool requiresTwoTransfers;
    }
    
    // Reward Tokens
    mapping (address => RewardToken) rewardTokens;
    
    // Main Contract Address
    address public main;

    // Pancakeswap Router
    address constant v2router = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    
    // shareholder fields
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    mapping (address => Share) public shares;
    
    // shares math and fields
    uint256 public totalShares;
    uint256 public totalDividends;
    uint256 public dividendsPerShare;
    uint256 constant dividendsPerShareAccuracyFactor = 10 ** 18;
    
    // blocks until next distribution
    uint256 public minPeriod = 14400;
    // auto claim every hour if able
    uint256 public constant minAutoPeriod = 1200;
    // 20,000 Minimum Distribution For Main
    uint256 public minDistribution = 5 * 10**16;
    // current index in shareholder array 
    uint256 currentIndex;
    
    // owner of token contract - used to pair with Vault Token
    address _tokenOwner;
    
    modifier onlyToken() {
        require(msg.sender == _token); _;
    }
    
    modifier onlyTokenOwner() {
        require(msg.sender == _tokenOwner, 'Invalid Entry'); _;
    }

    constructor (address _main) {
        rewardTokens[_main] = RewardToken({
           isApproved:true,
           buyerAddress:_main,
           dexRouter:v2router,
           requiresTwoTransfers:true
        });
        main = _main;
        _tokenOwner = msg.sender;
    }
    
    ///////////////////////////////////////////////
    //////////      Only Token Owner    ///////////
    ///////////////////////////////////////////////
    
    function pairToken(address token) external onlyTokenOwner {
        require(_token == address(0) && token != address(0), 'Token Already Paired');
        _token = token;
        emit TokenPaired(token);
    }
    
    function approveTokenForSwap(address token, address buyerContract, bool isSurgeToken) external onlyTokenOwner {
        _approveTokenForSwap(token, buyerContract, isSurgeToken, v2router);
    }
    
    function approveTokenForSwapCustomRouter(address token, address buyerContract, bool isSurgeToken, address router) external onlyTokenOwner {
        _approveTokenForSwap(token, buyerContract, isSurgeToken, router);
    }
    
    function removeTokenFromSwap(address token) external onlyTokenOwner {
        delete rewardTokens[token];
        emit RemovedTokenForSwapping(token);
    }
    
    /** New Main Address */
    function setMainTokenAddress(address newMainToken) external onlyTokenOwner {
        require(main != newMainToken && newMainToken != address(0), 'Invalid Input');
        require(rewardTokens[newMainToken].isApproved, 'New Main Not Approved');
        uint256 bal = IERC20(main).balanceOf(address(this));
        if (bal > 0) {
            IERC20(main).transfer(_tokenOwner, bal);
        }
        main = newMainToken;
    }
    
    /** Upgrades To New Distributor */
    function upgradeDistributor(address newDistributor) external onlyTokenOwner {
        require(newDistributor != address(this) && newDistributor != address(0), 'Invalid Input');
        uint256 mainBal = IERC20(main).balanceOf(address(this));
        if (mainBal > 0) IERC20(main).transfer(newDistributor, mainBal);
        selfdestruct(payable(newDistributor));
    }
    
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external onlyTokenOwner {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
    }
    
    ///////////////////////////////////////////////
    //////////    Only Token Contract   ///////////
    ///////////////////////////////////////////////
    
    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeMainDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcluded = getCumulativeMainDividends(shares[shareholder].amount);
    }
    
    ///////////////////////////////////////////////
    //////////      Public Functions    ///////////
    ///////////////////////////////////////////////
    
    function claimDividendInDesiredToken(address shareholder, address desiredToken) external nonReentrant{
        address previous = getRewardTokenForHolder(shareholder);
        _setRewardTokenForHolder(shareholder, desiredToken);
        _claimDividend(shareholder);
        _setRewardTokenForHolder(shareholder, previous);
    }
    
    function claimDividend(address shareholder) external nonReentrant {
        _claimDividend(shareholder);
    }
    
    function setRewardTokenForHolder(address token) external {
        _setRewardTokenForHolder(msg.sender, token);
    }
    
    function process(uint256 gas) external override {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        uint256 iterations = 0;
        
        while(gasUsed < gas && iterations < shareholderCount) {
            if(currentIndex >= shareholderCount){
                currentIndex = 0;
            }
            
            if(shouldDistributeMain(shareholders[currentIndex])){
                distributeMainDividend(shareholders[currentIndex]);
            }
            
            gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
            gasLeft = gasleft();
            currentIndex++;
            iterations++;
        }
    }


    ///////////////////////////////////////////////
    //////////    Internal Functions    ///////////
    ///////////////////////////////////////////////


    function addShareholder(address shareholder) internal {
        shareholderIndexes[shareholder] = shareholders.length;
        shareholders.push(shareholder);
    }

    function removeShareholder(address shareholder) internal { 
        shareholders[shareholderIndexes[shareholder]] = shareholders[shareholders.length-1];
        shareholderIndexes[shareholders[shareholders.length-1]] = shareholderIndexes[shareholder]; 
        shareholders.pop();
        delete shareholderIndexes[shareholder];
    }
    
    function _setRewardTokenForHolder(address holder, address token) private {
        uint256 minimum = IERC20(_token).totalSupply().div(10**5);
        require(shares[holder].amount > minimum, 'Sender Balance Too Small');
        require(rewardTokens[token].isApproved, 'Token Not Approved');
        shares[holder].rewardToken = token;
    }
    
    function _approveTokenForSwap(address token, address buyerContract, bool isSurgeToken, address router) private {
        rewardTokens[token] = RewardToken({
            isApproved: true,
            buyerAddress: buyerContract,
            dexRouter: router,
            requiresTwoTransfers: isSurgeToken
        });
        emit ApproveTokenForSwapping(token);
    } 

    function distributeMainDividend(address shareholder) internal nonReentrant {
        if(shares[shareholder].amount == 0){ return; }
        
        uint256 amount = getUnpaidMainEarnings(shareholder);
        if(amount >= minDistribution){
            
            address token = getRewardTokenForHolder(shareholder);
            shares[shareholder].totalExcluded = getCumulativeMainDividends(shares[shareholder].amount);
            shareholderClaims[shareholder] = block.number;
            
            if (rewardTokens[token].requiresTwoTransfers) {
                buyTokenTransferToHolder(token, shareholder, amount);
            } else {
                buyTokenForHolder(token, shareholder, amount);
            }
        }
    }
    
    function buyTokenTransferToHolder(address token, address shareholder, uint256 amount) private {
       
       uint256 balBefore = IERC20(token).balanceOf(address(this));
        (bool succ,) = payable(rewardTokens[token].buyerAddress).call{value: amount}("");
        if (succ) {
            uint256 dif = IERC20(token).balanceOf(address(this)).sub(balBefore);
            if (dif > 0) {
                shareholderClaims[shareholder] = block.number;
                try IERC20(token).transfer(shareholder, dif) {} catch {}
            }
        }
    }
    
    function buyTokenForHolder(address token, address shareholder, uint256 amount) private {
        
        IUniswapV2Router02 router = IUniswapV2Router02(rewardTokens[token].dexRouter);
        
        // Swap on PCS
        address[] memory mainPath = new address[](2);
        mainPath[0] = router.WETH();
        mainPath[1] = token;
            
        try router.swapExactETHForTokens{value:amount}(
            0,
            mainPath,
            shareholder,
            block.timestamp.add(30)
        ) { } catch{}
    }
    
    function _claimDividend(address shareholder) private {
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidMainEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
        // update shareholder data
        address token = getRewardTokenForHolder(shareholder);
        shares[shareholder].totalExcluded = getCumulativeMainDividends(shares[shareholder].amount);
        shareholderClaims[shareholder] = block.number;
            
        if (rewardTokens[token].requiresTwoTransfers) {
            buyTokenTransferToHolder(token, shareholder, amount);
        } else {
            buyTokenForHolder(token, shareholder, amount);
        }
    }
    
    ///////////////////////////////////////////////
    //////////      Read Functions      ///////////
    ///////////////////////////////////////////////
    
    function shouldDistributeMain(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.number
        && getUnpaidMainEarnings(shareholder) >= minDistribution;
    }
    
    function getShareholders() external view returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) external view returns(uint256) {
        return shares[holder].amount;
    }

    function getUnpaidMainEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeMainDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcluded;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }
    
    function getRewardTokenForHolder(address holder) public view returns (address) {
        return shares[holder].rewardToken == address(0) ? main : shares[holder].rewardToken;
    }

    function getCumulativeMainDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShare).div(dividendsPerShareAccuracyFactor);
    }
    
    function isTokenApprovedForSwapping(address token) external view returns (bool) {
        return rewardTokens[token].isApproved;
    }

    // EVENTS 
    event TokenPaired(address pairedToken);
    event ApproveTokenForSwapping(address token);
    event RemovedTokenForSwapping(address token);
    event SwappedTokenAddresses(address newMain, address newXParent);
    event UpdateDistributorCriteria(uint256 minPeriod, uint256 minDistribution, uint256 minParentDistribution);

    receive() external payable {
        // update main dividends
        totalDividends = totalDividends.add(msg.value);
        dividendsPerShare = dividendsPerShare.add(dividendsPerShareAccuracyFactor.mul(msg.value).div(totalShares));
    }

}
