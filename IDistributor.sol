//SPDX-License-Identifier: MIT
pragma solidity 0.8.0;

interface IDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external;
    function process(uint256 gas) external;
    function upgradeDistributor(address newDistributor) external;
    function claimMainDividend(address sender) external;
    function setDistributeXTokens(bool distributeX) external;
    function claimParentDividend(address sender) external;
    function updatePancakeRouterAddress(address pcs) external;
    function updateXTradeManager(address newManager) external;
    function setMainTokenAddress(address main) external;
    function setTokenOwner(address newOwner) external;
    function setParentTokenAddress(address parent, address xParent) external;
}