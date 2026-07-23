// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC3643TokenMinimal} from "./IERC3643TokenMinimal.sol";

interface IRealisticTokenAdmin {
    function addAgent(address a) external;
    function removeAgent(address a) external;
    function isAgent(address a) external view returns (bool);
    function pause() external;
    function unpause() external;
    function setIdentityVerified(address user, bool verified) external;
    function setComplianceResult(address from, address to, uint256 amount, bool allowed) external;
    function balanceOf(address a) external view returns (uint256);
}

contract RealisticERC3643Token is IERC3643TokenMinimal {
    mapping(address => uint256) public balanceOf;
    mapping(address => bool) private _agents;
    mapping(address => bool) private _verified;
    mapping(bytes32 => bool) private _complianceOverrides;
    bool private _paused;
    address private _owner;

    event AgentAdded(address a);
    event AgentRemoved(address a);
    event Paused();
    event Unpaused();

    modifier onlyAgent() {
        require(_agents[msg.sender], "not agent");
        _;
    }

    modifier whenNotPaused() {
        require(!_paused, "paused");
        _;
    }

    constructor() {
        _owner = msg.sender;
        _agents[msg.sender] = true;
    }

    function addAgent(address a) external {
        require(msg.sender == _owner, "not owner");
        _agents[a] = true;
        emit AgentAdded(a);
    }

    function removeAgent(address a) external {
        require(msg.sender == _owner, "not owner");
        _agents[a] = false;
        emit AgentRemoved(a);
    }

    function isAgent(address a) external view returns (bool) {
        return _agents[a];
    }

    function pause() external onlyAgent {
        _paused = true;
        emit Paused();
    }

    function unpause() external onlyAgent {
        _paused = false;
        emit Unpaused();
    }

    function setIdentityVerified(address user, bool verified) external {
        require(msg.sender == _owner, "not owner");
        _verified[user] = verified;
    }

    function setComplianceResult(address from, address to, uint256 amount, bool allowed) external {
        require(msg.sender == _owner, "not owner");
        _complianceOverrides[keccak256(abi.encode(from, to, amount))] = allowed;
    }

    function mint(address to, uint256 amount) external onlyAgent whenNotPaused {
        require(_verified[to], "identity not verified");
        require(
            _complianceOverrides[keccak256(abi.encode(address(0), to, amount))],
            "compliance not satisfied"
        );
        balanceOf[to] += amount;
    }

    function burn(address from, uint256 amount) external onlyAgent {
        require(balanceOf[from] >= amount, "insufficient balance");
        balanceOf[from] -= amount;
    }

    function compliance() external view returns (address) {
        return address(0);
    }

    function identityRegistry() external view returns (address) {
        return address(0);
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function setOwner(address newOwner) external {
        require(msg.sender == _owner, "not owner");
        _owner = newOwner;
    }
}
