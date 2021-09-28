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
    address _token;
    
    // Share of Vault
    struct Share {
        uint256 amount;
        uint256 totalExcludedParent;
        uint256 totalExcludedMain;
    }
    
    // Main Contract Address
    address main;
    // xParent Contract Address
    address xParent;

    // Pancakeswap Router
    IUniswapV2Router02 router;
    
    // shareholder fields
    address[] shareholders;
    mapping (address => uint256) shareholderIndexes;
    mapping (address => uint256) shareholderClaims;
    mapping (address => Share) public shares;
    
    // shares math and fields
    uint256 public totalShares;
    uint256 public totalDividendsMain;
    uint256 public dividendsPerShareMain;
    uint256 public totalDividendsParent;
    uint256 public dividendsPerShareParent;
    uint256 constant dividendsPerShareAccuracyFactor = 10 ** 36;
    
    // blocks until next distribution
    uint256 public minPeriod = 1200;
    // auto claim every 60 seconds if able
    uint256 public constant minAutoPeriod = 20;
    // 20,000 Minimum Distribution For Main
    uint256 public minMainDistribution = 2 * 10**4;
    // 20,000 Minimum Distribution For Parent
    uint256 public minParentDistribution = 2 * 10**4 * 10**9;
    // current index in shareholder array 
    uint256 currentIndexMain;
    // current index in shareholder array 
    uint256 currentIndexParent;
    
    // distribution turn
    bool mainsTurnPurchase = false;
    bool mainsTurnDistribute = true;
    
    // owner of token contract - used to pair with Vault Token
    address tokenSetter;
    
    // auto rewards disabled
    mapping( address => bool ) autoRewardsDisabledForUser;
    
    // approved tokens to swap between
    mapping( address => bool ) approvedSwapToken;
    
    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _main, address _xParent) {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        main = _main;
        xParent = _xParent;
        tokenSetter = msg.sender;
    }
    
    function pairToken(address token) external {
        require(_token == address(0) && token != address(0), 'Token Already Paired');
        require(msg.sender == tokenSetter, 'Invalid Entry');
        _token = token;
        emit TokenPaired(token);
    }
    
    function approveTokenForSwap(address token, bool isApproved) external {
        require(msg.sender == tokenSetter, 'Invalid Entry');
        approvedSwapToken[token] = isApproved;
        emit ApproveTokenForSwapping(token, isApproved);
    }
    
    function isTokenApprovedForSwapping(address token) external view returns (bool) {
        return approvedSwapToken[token];
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minMainDistribution, uint256 _minParentDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minMainDistribution = _minMainDistribution;
        minParentDistribution = _minParentDistribution;
    }

    function setShare(address shareholder, uint256 amount) external override onlyToken {
        if(shares[shareholder].amount > 0){
            distributeParentDividend(shareholder);
            distributeMainDividend(shareholder);
        }

        if(amount > 0 && shares[shareholder].amount == 0){
            addShareholder(shareholder);
        }else if(amount == 0 && shares[shareholder].amount > 0){
            removeShareholder(shareholder);
        }

        totalShares = totalShares.sub(shares[shareholder].amount).add(amount);
        shares[shareholder].amount = amount;
        shares[shareholder].totalExcludedParent = getCumulativeParentDividends(shares[shareholder].amount);
        shares[shareholder].totalExcludedMain = getCumulativeMainDividends(shares[shareholder].amount);
    }
    
    function deposit() external override onlyToken {
        if (address(this).balance < 10**14) return;

        if (mainsTurnPurchase) {
            // balance before
            uint256 balanceBefore = IERC20(main).balanceOf(address(this));
            // buy Main
            (bool success,) = payable(main).call{value: address(this).balance}("");
            // balance after
            uint256 amount = IERC20(main).balanceOf(address(this)).sub(balanceBefore);
            // update dividends
            totalDividendsMain = totalDividendsMain.add(amount);
            dividendsPerShareMain = dividendsPerShareMain.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
            require(success, 'Failure On Main Purchase');
        } else {
            // balance before
            uint256 balanceBefore = IERC20(xParent).balanceOf(address(this));
            // buy Main
            (bool success,) = payable(xParent).call{value: address(this).balance.div(8)}("");
            // balance after
            uint256 amount = IERC20(xParent).balanceOf(address(this)).sub(balanceBefore);
            // update dividends
            totalDividendsParent = totalDividendsParent.add(amount);
            dividendsPerShareParent = dividendsPerShareParent.add(dividendsPerShareAccuracyFactor.mul(amount).div(totalShares));
            require(success, 'Failure On xParent Purchase');
        }
        mainsTurnPurchase = !mainsTurnPurchase;
    }

    function process(uint256 gas) external override onlyToken {
        uint256 shareholderCount = shareholders.length;

        if(shareholderCount == 0) { return; }

        uint256 gasUsed = 0;
        uint256 gasLeft = gasleft();

        mainsTurnDistribute = !mainsTurnDistribute;
        uint256 iterations = 0;
        
        if (mainsTurnDistribute) {
            
            while(gasUsed < gas && iterations < shareholderCount) {
                if(currentIndexMain >= shareholderCount){
                    currentIndexMain = 0;
                }

                if(shouldDistributeMain(shareholders[currentIndexMain])){
                    distributeMainDividend(shareholders[currentIndexMain]);
                }
            
                gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
                gasLeft = gasleft();
                currentIndexMain++;
                iterations++;
            }
            
        } else {
            
            while(gasUsed < gas && iterations < shareholderCount) {
                if(currentIndexParent >= shareholderCount){
                    currentIndexParent = 0;
                }

                if(shouldDistributeParent(shareholders[currentIndexParent])){
                    distributeParentDividend(shareholders[currentIndexParent]);
                }

                gasUsed = gasUsed.add(gasLeft.sub(gasleft()));
                gasLeft = gasleft();
                currentIndexParent++;
                iterations++;
            }
            
        }
        
    }

    function shouldDistributeParent(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.number
        && !autoRewardsDisabledForUser[shareholder]
        && getUnpaidParentEarnings(shareholder) >= minParentDistribution;
    }
    
    function shouldDistributeMain(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.number
        && !autoRewardsDisabledForUser[shareholder]
        && getUnpaidMainEarnings(shareholder) >= minMainDistribution;
    }

    function distributeParentDividend(address shareholder) internal nonReentrant {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidParentEarnings(shareholder);
        if(amount > 0){
            bool success = IERC20(xParent).transfer(shareholder, amount);
            if (success) {
                shareholderClaims[shareholder] = block.number;
                shares[shareholder].totalExcludedParent = getCumulativeParentDividends(shares[shareholder].amount);
            }
        }
    }
    
    function distributeMainDividend(address shareholder) internal nonReentrant {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidMainEarnings(shareholder);
        if(amount > 0){
            bool success = IERC20(main).transfer(shareholder, amount);
            if (success) {
                shareholderClaims[shareholder] = block.number;
                shares[shareholder].totalExcludedMain = getCumulativeMainDividends(shares[shareholder].amount);
            }
        }   
    }
    
    function claimMainDividend(address shareholder) external override onlyToken {
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidMainEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
        // update shareholder data
        shareholderClaims[shareholder] = block.number;
        shares[shareholder].totalExcludedMain = getCumulativeMainDividends(shares[shareholder].amount);
        bool success = IERC20(main).transfer(shareholder, amount);
        require(success, 'Failure On Main Transfer');
    }
    
    function claimParentDividend(address shareholder) external override onlyToken {
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidParentEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
        // update shareholder data
        shareholderClaims[shareholder] = block.number;
        shares[shareholder].totalExcludedParent = getCumulativeParentDividends(shares[shareholder].amount);
        bool success = IERC20(xParent).transfer(shareholder, amount);
        require(success, 'Failure On Parent Transfer');
    }
    
    function claimxParentDividendInDesiredToken(address shareholder, address xTokenDesired) external override onlyToken nonReentrant{
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Timeout');
        require(approvedSwapToken[xTokenDesired], 'xToken Not Approved For Swapping');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidParentEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
            
        // update Shareholder information
        shareholderClaims[shareholder] = block.number;
        shares[shareholder].totalExcludedParent = getCumulativeParentDividends(shares[shareholder].amount);
            
        // Swap on PCS
        address[] memory tokenPath = new address[](2);
        tokenPath[0] = xParent;
        tokenPath[1] = xTokenDesired;
            
        // approve transaction
        IERC20(xParent).approve(address(router), amount);

        // Swap Token for Token
        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0, // accept as many xTokens as we can
            tokenPath,
            shareholder, // Send To Shareholder
            block.timestamp.add(30)
        ) {} catch{revert('Failure On xToken Swap');}
    }
    
    function claimMainDividendInDesiredSurgeToken(address shareholder, address desiredMain) external override onlyToken nonReentrant{
        require(shareholderClaims[shareholder] + minAutoPeriod < block.number, 'Not Time Yet');
        require(approvedSwapToken[desiredMain], 'Surge Token Not Approved For Swapping');
        require(shares[shareholder].amount > 0, 'Zero Balance');
        uint256 amount = getUnpaidMainEarnings(shareholder);
        require(amount > 0, 'Zero Amount Owed');
            
        // update Shareholder information
        shareholderClaims[shareholder] = block.number;
        shares[shareholder].totalExcludedMain = getCumulativeMainDividends(shares[shareholder].amount);
            
        // Swap on PCS
        address[] memory mainPath = new address[](2);
        mainPath[0] = main;
        mainPath[1] = desiredMain;
            
        // approve transaction
        IERC20(main).approve(address(router), amount);
            
        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount,
            0,
            mainPath,
            shareholder,
            block.timestamp.add(30)
        ) {} catch{revert('Error on Main Token Swap');}
        
    }
    
    function getShareholders() external view returns (address[] memory) {
        return shareholders;
    }
    
    function getShareForHolder(address holder) external view returns(uint256) {
        return shares[holder].amount;
    }

    function getUnpaidParentEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeParentDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcludedParent;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }
    
    function getUnpaidMainEarnings(address shareholder) public view returns (uint256) {
        if(shares[shareholder].amount == 0){ return 0; }

        uint256 shareholderTotalDividends = getCumulativeMainDividends(shares[shareholder].amount);
        uint256 shareholderTotalExcluded = shares[shareholder].totalExcludedMain;

        if(shareholderTotalDividends <= shareholderTotalExcluded){ return 0; }

        return shareholderTotalDividends.sub(shareholderTotalExcluded);
    }

    function getCumulativeParentDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShareParent).div(dividendsPerShareAccuracyFactor);
    }
    
    function getCumulativeMainDividends(uint256 share) internal view returns (uint256) {
        return share.mul(dividendsPerShareMain).div(dividendsPerShareAccuracyFactor);
    }

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

    /** Updates the Address of the PCS Router */
    function updatePancakeRouterAddress(address pcsRouter) external override onlyToken {
        router = IUniswapV2Router02(pcsRouter);
    }
    
    /** Enables or Disables Auto Rewards For Holder */
    function changeAutoRewardsForShareholder(address shareholder, bool rewardsDisabled) external override onlyToken {
        autoRewardsDisabledForUser[shareholder] = rewardsDisabled;
    } 
    
    /** New Parent Address */
    function setParentTokenAddress(address xParentToken) external override onlyToken {
        require(xParent != xParentToken && xParentToken != address(0), 'Invalid Input');
        uint256 xbal = IERC20(xParent).balanceOf(address(this));
        if (xbal > 0) {
            IERC20(xParent).transfer(xParent, xbal);
        }
        xParent = xParentToken;
    }
    
    /** New Main Address */
    function setMainTokenAddress(address newMainToken) external override onlyToken {
        require(main != newMainToken && newMainToken != address(0), 'Invalid Input');
        uint256 bal = IERC20(main).balanceOf(address(this));
        if (bal > 0) {
            IERC20(main).transfer(xParent, bal);
        }
        main = newMainToken;
    }
    
    /** Upgrades To New Distributor */
    function upgradeDistributor(address newDistributor) external override onlyToken {
        require(newDistributor != address(this) && newDistributor != address(0), 'Invalid Input');
        uint256 mainBal = IERC20(main).balanceOf(address(this));
        if (mainBal > 0) IERC20(main).transfer(newDistributor, mainBal);
        uint256 xParentBal = IERC20(xParent).balanceOf(address(this));
        if (xParentBal > 0) IERC20(xParent).transfer(newDistributor, xParentBal);
        selfdestruct(payable(newDistributor));
    }

    // EVENTS 
    event TokenPaired(address pairedToken);
    event ApproveTokenForSwapping(address token, bool isApproved);

    receive() external payable { }

}
