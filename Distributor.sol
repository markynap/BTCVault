//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

import "./IDistributor.sol";
import "./SafeMath.sol";
import "./Address.sol";
import "./IERC20.sol";
import "./IUniswapV2Router02.sol";
import "./XTradeManager.sol";

/** Distributes Vault Tokens and Surge Tokens To Holders Varied on Weight */
contract Distributor is IDistributor {
    
    using SafeMath for uint256;
    using Address for address;
    
    // Vault Contract
    address _token;
    // Share of Vault
    struct Share {
        uint256 amount;
        uint256 totalExcludedParent;
        uint256 totalRealisedParent;
        uint256 totalExcludedMain;
        uint256 totalRealisedMain;
    }
    // Main Contract Address
    address main;
    // Parent Contract Address
    address parent;
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

    uint256 public dividendsPerShareAccuracyFactor = 10 ** 36;
    // distributes twice per day
    uint256 public minPeriod = 4 hours;
    // auto claim
    uint256 public minAutoPeriod = 10;
    // 20,000 Minimum Distribution
    uint256 public minDistribution = 2 * 10**4;
    // BNB Used To Swap To Parent
    uint256 public parentDenom = 8;
    // current index in shareholder array 
    uint256 currentIndexMain;
    // current index in shareholder array 
    uint256 currentIndexParent;
    
    bool mainsTurnPurchase = false;
    bool mainsTurnDistribute = true;
    
    // For xTokens
    XTradeManager manager;
    // Personal xTrader
    XTrader myBridge;
    
    // owner of token contract - used to pair with Vault Token
    address tokenOwner;
    
    // BNB -> Parent
    address[] path;
    
    // distribute xTokens or Native
    bool distributeXTokens;
    
    event TokenPaired(address pairedToken);
    
    modifier onlyToken() {
        require(msg.sender == _token); _;
    }

    constructor (address _main, address _parent, address _xParent) {
        router = IUniswapV2Router02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
        main = _main;
        parent = _parent;
        xParent = _xParent;
        tokenOwner = msg.sender;
        manager = XTradeManager(0x97d84ed359A2dB7788E9D7263b9a84F315a5D84B);
        address ca = manager.createXTrader(address(this));
        myBridge = XTrader(payable(ca));
        path = new address[](2);
        path[0] = router.WETH();
        path[1] = parent;
        distributeXTokens = true;
    }
    
    function pairToken(address token) external {
        require(_token == address(0) && token != address(0), 'Token Already Paired');
        require(msg.sender == tokenOwner, 'Token Owner Must Pair Distributor');
        _token = token;
        tokenOwner = address(0);
        emit TokenPaired(token);
    }

    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external override onlyToken {
        minPeriod = _minPeriod;
        minDistribution = _minDistribution;
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
            mainsTurnPurchase = false;
            require(success, 'Failure On Main Purchase');
            
        } else {
            // tokens before swap
            uint256 amountNativeBefore = IERC20(parent).balanceOf(address(this));
            
            // buy Parent
            try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: address(this).balance.div(8)}(
                0,
                path,
                address(this),
                block.timestamp.add(30)
            ) {} catch {return;}
            
            // tokens after
            uint256 amount = IERC20(parent).balanceOf(address(this));
            
            if (distributeXTokens) {
                
                // amount xParent
                uint256 amountXBefore = IERC20(xParent).balanceOf(address(this));
                // turn Parent into xParent
                IERC20(parent).approve(address(myBridge), amount);
                myBridge.buyXTokenWithNonSurgeToken(parent, amount, xParent);
                // how many xTokens did we receive
                uint256 xReceived = IERC20(xParent).balanceOf(address(this)).sub(amountXBefore);
                // update dividends
                totalDividendsParent = totalDividendsParent.add(xReceived);
                dividendsPerShareParent = dividendsPerShareParent.add(dividendsPerShareAccuracyFactor.mul(xReceived).div(totalShares));
                mainsTurnPurchase = true;
                
            } else {
                
                // amount parent
                uint256 received = amount.sub(amountNativeBefore);
                // update dividends
                totalDividendsParent = totalDividendsParent.add(received);
                dividendsPerShareParent = dividendsPerShareParent.add(dividendsPerShareAccuracyFactor.mul(received).div(totalShares));
                mainsTurnPurchase = true;
                
            }
            
        }
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
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
        && getUnpaidParentEarnings(shareholder) > minDistribution;
    }
    
    function shouldDistributeMain(address shareholder) internal view returns (bool) {
        return shareholderClaims[shareholder] + minPeriod < block.timestamp
        && getUnpaidMainEarnings(shareholder) > minDistribution;
    }

    function distributeParentDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidParentEarnings(shareholder);
        if(amount > 0){
            bool success = IERC20(parent).transfer(shareholder, amount);
            if (success) {
                shareholderClaims[shareholder] = block.timestamp;
                shares[shareholder].totalRealisedParent = shares[shareholder].totalRealisedParent.add(amount);
                shares[shareholder].totalExcludedParent = getCumulativeParentDividends(shares[shareholder].amount);
            }
        }
    }
    
    function distributeMainDividend(address shareholder) internal {
        if(shares[shareholder].amount == 0){ return; }

        uint256 amount = getUnpaidMainEarnings(shareholder);
        if(amount > 0){
            bool success = IERC20(main).transfer(shareholder, amount);
            if (success) {
                shareholderClaims[shareholder] = block.timestamp;
                shares[shareholder].totalRealisedMain = shares[shareholder].totalRealisedMain.add(amount);
                shares[shareholder].totalExcludedMain = getCumulativeMainDividends(shares[shareholder].amount);
            }
        }   
    }
    
    function claimMainDividend(address claimer) external override onlyToken {
        require(shareholderClaims[claimer] + minAutoPeriod < block.timestamp, 'must wait at least the minimum auto withdraw period');
        distributeMainDividend(claimer);
    }
    
    function claimParentDividend(address claimer) external override onlyToken {
        require(shareholderClaims[claimer] + minAutoPeriod < block.timestamp, 'must wait at least the minimum auto withdraw period');
        distributeParentDividend(claimer);
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
        path[0] = router.WETH();
    }
    
    /** New Parent Address */
    function setParentTokenAddress(address newParentToken, address xParentToken) external override onlyToken {
        require(parent != newParentToken, 'Cannot Change To Same Token');
        uint256 bal = IERC20(parent).balanceOf(address(this));
        if (bal > 0) {
            IERC20(parent).transfer(tokenOwner, bal);
        }
        uint256 xbal = IERC20(xParent).balanceOf(address(this));
        if (xbal > 0) {
            IERC20(xParent).transfer(tokenOwner, bal);
        }
        parent = newParentToken;
        path[1] = newParentToken;
        xParent = xParentToken;
    }
    
    /** New Main Address */
    function setMainTokenAddress(address newMainToken) external override onlyToken {
        require(main != newMainToken, 'Cannot Change To Same Token');
        uint256 bal = IERC20(main).balanceOf(address(this));
        if (bal > 0) {
            IERC20(main).transfer(tokenOwner, bal);
        }
        main = newMainToken;
    }
    
    /** Sets The Owner of the Vault Token */
    function setTokenOwner(address newOwner) external override onlyToken {
        tokenOwner = newOwner;
    }
    
    /** Upgrades The Bridge Manager */
    function updateXTradeManager(address newManager) external override onlyToken {
        manager = XTradeManager(newManager);
        address ca = manager.createXTrader(address(this));
        myBridge = XTrader(payable(ca));
    }
    
    function setDistributeXTokens(bool distributeX) external override onlyToken {
        distributeXTokens = distributeX;
        if (distributeX) {
            uint256 bal = IERC20(parent).balanceOf(address(this));
            if (bal > 0) myBridge.buyXTokenWithNonSurgeToken(parent, bal, xParent); 
        } else {
            uint256 bal = IERC20(xParent).balanceOf(address(this));
            if (bal > 0) myBridge.sellXTokenForNative(xParent, bal);
        }
    }
    
    /** Upgrades To New Distributor */
    function upgradeDistributor(address newDistributor) external override onlyToken {
        uint256 mainBal = IERC20(main).balanceOf(address(this));
        bool succ = IERC20(main).transfer(newDistributor, mainBal);
        uint256 parentBal = IERC20(parent).balanceOf(address(this));
        bool succ1 = IERC20(parent).transfer(newDistributor, parentBal);
        uint256 xParentBal = IERC20(xParent).balanceOf(address(this));
        bool succ2 = IERC20(xParent).transfer(newDistributor, xParentBal);
        if (succ && succ1 && succ2) {
            selfdestruct(payable(newDistributor));
        }
    }

    receive() external payable { }

}