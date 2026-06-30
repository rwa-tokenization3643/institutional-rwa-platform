// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ProtocolTypes} from "../common/ProtocolTypes.sol";

/// @title Compliance Policy Provider Interface
/// @notice Provider-agnostic interface for compliance policy evaluation.
/// @dev Every policy engine (Chainlink ACE, custom Solidity rule engine,
///      jurisdiction policy provider, AML/risk provider, future ZK verifier)
///      implements this interface. The SettlementCoordinator evaluates
///      transfer compliance through this interface without knowing the
///      underlying engine.
///
///      A CompliancePolicyProvider is responsible ONLY for evaluating
///      policy. It MUST NOT modify settlement state, mint or burn tokens,
///      send transport messages, manage identities, or update ERC-3643
///      contracts.
///
///      Providers SHOULD be stateless from the SettlementCoordinator's
///      perspective. Evaluating an intent is a `view` function — it MUST
///      NOT modify any state.
///
///      Common compliance events (`ComplianceEvaluationRequested`,
///      `ComplianceEvaluationCompleted`) should be defined in
///      ProtocolEvents.sol once that shared library exists, rather than
///      baked into this interface.
///
///      Policy-level errors should be defined in ProtocolErrors.sol once
///      that shared library exists. Until then, implementers should define
///      their own errors following the naming convention
///      `CompliancePolicyProvider__<ErrorName>`.
///
///      Implementations MUST support ERC-165 for interface detection.
///
///      The SettlementCoordinator MUST never know which concrete provider
///      implements this interface.
interface ICompliancePolicyProvider is IERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Evaluation
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Evaluates a transfer intent against the provider's compliance
    ///         policies.
    /// @dev The provider MUST use only the fields within `intent` to reach a
    ///      decision. It MUST NOT rely on external state that can change
    ///      between evaluation and settlement. This is a `view` function —
    ///      it MUST NOT modify any state.
    /// @param intent The transfer intent to evaluate.
    /// @return decision The compliance decision, including the result and
    ///                  a hash of the evaluation inputs for auditability.
    function evaluateTransferIntent(
        ProtocolTypes.TransferIntent calldata intent
    ) external view returns (ProtocolTypes.ComplianceDecision memory decision);

    // ═══════════════════════════════════════════════════════════════════════
    // Policy Versioning
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the currently active policy version identifier.
    /// @return policyVersion Current policy version (e.g. semantic version
    ///                       hash or content-addressed policy digest).
    function currentPolicyVersion() external view returns (bytes32 policyVersion);

    /// @notice Returns whether the given policy version is supported by this
    ///         provider.
    /// @param policyVersion Version identifier to query.
    /// @return supported    True if the provider recognizes this version.
    function supportsPolicyVersion(bytes32 policyVersion) external view returns (bool supported);

    // ═══════════════════════════════════════════════════════════════════════
    // Capabilities
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Returns the unique identifier of this compliance provider.
    /// @return providerId Bytes32 identifier (e.g. `keccak256("ACE")`,
    ///                    `keccak256("RuleEngine")`).
    function getProviderId() external view returns (bytes32 providerId);

    /// @notice Returns a bitmask of supported capabilities.
    /// @dev Each bit corresponds to a `ComplianceCapability` enum value.
    ///      Consumers check support with
    ///      `(capabilities >> uint256(ComplianceCapability.XXX)) & 1 == 1`.
    /// @return capabilities Bitmask of supported capabilities.
    function getCapabilities() external view returns (uint256 capabilities);
}
