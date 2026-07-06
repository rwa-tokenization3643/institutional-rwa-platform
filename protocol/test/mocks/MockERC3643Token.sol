// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @title MockERC3643Token
/// @notice Minimal ERC-3643 token mock for testing the protocol's asset adapter.
///         Supports configurable mint/burn failure injection.
contract MockERC3643Token {
    mapping(address => uint256) public balanceOf;
    bool public shouldRevertMint;
    bool public shouldRevertBurn;

    function setShouldRevertMint(bool v) external { shouldRevertMint = v; }
    function setShouldRevertBurn(bool v) external { shouldRevertBurn = v; }

    function mint(address to, uint256 amount) external {
        require(!shouldRevertMint, "MockToken: mint reverted");
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external {
        require(!shouldRevertBurn, "MockToken: burn reverted");
        balanceOf[from] -= amount;
    }
}
