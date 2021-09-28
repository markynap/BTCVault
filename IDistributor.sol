//SPDX-License-Identifier: MIT
pragma solidity 0.8.4;

interface IDistributor {
    function setDistributionCriteria(uint256 _minPeriod, uint256 _minMainDistribution, uint256 _minParentDistribution) external;
    function setShare(address shareholder, uint256 amount) external;
    function deposit() external;
    function process(uint256 gas) external;
    function upgradeDistributor(address newDistributor) external;
    function claimMainDividend(address sender) external;
    function claimxParentDividendInDesiredToken(address shareholder, address xTokenDesired) external;
    function claimMainDividendInDesiredSurgeToken(address shareholder, address xMainTokenDesired) external;
    function changeAutoRewardsForShareholder(address shareholder, bool rewardsDisabled) external;
    function claimParentDividend(address sender) external;
    function updatePancakeRouterAddress(address pcs) external;
    function setMainTokenAddress(address newMainToken) external;
    function setParentTokenAddress(address xParent) external;
}
