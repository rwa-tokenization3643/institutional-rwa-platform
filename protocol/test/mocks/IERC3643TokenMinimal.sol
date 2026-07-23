// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IERC3643TokenMinimal {
    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function balanceOf(address account) external view returns (uint256);
    function addAgent(address account) external;
    function removeAgent(address account) external;
    function pause() external;
    function unpause() external;
    function paused() external view returns (bool);
    function isAgent(address account) external view returns (bool);
    function identityRegistry() external view returns (address);
    function compliance() external view returns (address);
}
