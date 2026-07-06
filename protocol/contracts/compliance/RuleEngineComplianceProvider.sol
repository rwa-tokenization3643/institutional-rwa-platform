// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProtocolAccessManager} from "../access/IProtocolAccessManager.sol";
import {ICompliancePolicyProvider} from "../interfaces/ICompliancePolicyProvider.sol";
import {ProtocolTypes, ChainId} from "../common/ProtocolTypes.sol";

/// @title RuleEngineComplianceProvider
/// @notice Protocol-centric compliance provider that evaluates TransferIntent
///         against configurable on-chain policy rules.
///
/// @dev
/// ── Role ──
///
/// This provider implements ICompliancePolicyProvider for the Institutional RWA
/// Platform. It acts as an internal rule engine that SettlementCoordinator calls
/// during Phase 1 validation (before assets are reserved) and Phase 2 settlement
/// (before mint/burn). The SettlementCoordinator communicates ONLY through
/// ICompliancePolicyProvider — it never depends on a specific compliance engine.
///
/// ── What It Evaluates ──
///
/// The provider runs a modular evaluation pipeline. Each private helper function
/// checks one dimension of compliance and returns either success or a
/// ComplianceFailureReason:
///
///   1. Action type         — Is the IntentAction allowed?
///   2. Sender identity     — Does the sender have a non-zero identity hash?
///   3. Recipient identity  — Does the recipient have a non-zero identity hash?
///   4. Asset               — Is the asset in the allowed-assets list?
///   5. Jurisdiction        — Are source/destination jurisdictions not blocked
///                            and (if allowlist mode) in the allowed list?
///   6. Investor class      — Are sender/recipient classified at or above the
///                            minimum classification threshold?
///   7. Transfer amount     — Does the amount not exceed the per-asset maximum?
///   8. Holding limit       — Does the amount not exceed the per-asset holding cap?
///                            NOTE: This is a per-transfer cap, not a running
///                            balance check. Full holding-limit enforcement
///                            requires querying the current holder balance from
///                            the token or adapter, which is outside this
///                            provider's scope.
///   9. Time validity       — Is the intent within its expiry window?
///
/// ── What It Does NOT Do ──
///
///   * Mint, burn, or transfer tokens.
///   * Send or receive cross-chain messages.
///   * Modify TransferIntent or settlement state.
///   * Call SettlementCoordinator, AssetAdapter, TransportProvider, or any
///     ERC-3643 / ONCHAINID contract.
///   * Connect to Chainlink ACE or any external oracle.
///
/// ── Explainability ──
///
/// Every rejection includes machine-readable failure reasons. Use
/// `evaluateWithReasons()` to get both the ComplianceDecision and the full
/// array of ComplianceFailureReason values. The decisionHash returned by
/// `evaluateTransferIntent()` is an auditable commitment to the evaluation
/// inputs and result.
///
/// ── Policy Versioning ──
///
/// The provider tracks a `currentPolicyVersion` that represents the active
/// policy configuration. When a COMPLIANCE_ROLE holder modifies any policy
/// parameter, they should also update the policy version (via
/// `setPolicyVersion`) to reflect the change. Previous versions remain
/// queryable through `supportsPolicyVersion`.
///
/// ── Future ACE Integration ──
///
/// This provider validates the protocol architecture *without* a dedicated
/// compliance oracle. Future iterations should replace or supplement this
/// provider with a Chainlink ACE adapter that evaluates policies off-chain.
/// The SettlementCoordinator requires no changes — it already communicates
/// through ICompliancePolicyProvider. Simply deploy the ACE adapter and
/// update the coordinator's provider reference.
///
/// ── Assumptions ──
///
///   * Identity hashes (senderIdentityHash, recipientIdentityHash) are
///     pre-verified by the caller. This provider checks only non-zero.
///   * Jurisdictions are configured per chain ID by a COMPLIANCE_ROLE holder.
///   * Investor classifications are maintained off-chain and pushed to this
///     contract by a COMPLIANCE_ROLE holder via `setInvestorClassification`.
///   * Holding limits check only the transfer amount, not running balances.
///     Full enforcement requires the SettlementCoordinator or AssetAdapter
///     to verify holding limits after mint/burn.
contract RuleEngineComplianceProvider is ICompliancePolicyProvider, ERC165 {

    // ═══════════════════════════════════════════════════════════════════════
    // Errors
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolErrors.sol

    /// @dev Zero address where a non-zero is required.
    error RuleEngine__ZeroAddress();

    /// @dev The caller does not hold the required role.
    error RuleEngine__UnauthorizedRole(address caller, bytes32 requiredRole);

    /// @dev Policy version string must not be empty.
    error RuleEngine__EmptyPolicyVersion();

    /// @dev The investor classification value is out of the valid range.
    error RuleEngine__InvalidClassification(uint8 classification);

    // ═══════════════════════════════════════════════════════════════════════
    // Events
    // ═══════════════════════════════════════════════════════════════════════
    // TODO: Replace with ProtocolEvents.sol

    /// @dev Emitted when the active policy version is updated.
    event PolicyVersionUpdated(bytes32 indexed oldVersion, bytes32 indexed newVersion);

    /// @dev Emitted when a compliance parameter is changed by an authorized role.
    event ComplianceConfigUpdated(bytes32 indexed configKey);

    // ═══════════════════════════════════════════════════════════════════════
    // Constants
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Unique identifier for this compliance provider.
    bytes32 public constant PROVIDER_ID = keccak256("RuleEngine");

    /// @notice Version of this provider implementation.
    bytes32 public constant PROVIDER_VERSION = keccak256("RuleEngine:1.0.0");

    // ═══════════════════════════════════════════════════════════════════════
    // Types
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Machine-readable reason for a compliance failure.
    /// @dev Each value corresponds to a specific rule evaluation failure.
    ///      Values with the suffix _BLOCKED refer to explicit deny-list
    ///      entries; values with suffix _NOT_ALLOWED refer to allow-list
    ///      membership checks.
    enum ComplianceFailureReason {
        /// @dev No failure (placeholder).
        NONE,
        /// @dev Transfer action type is not in the allowed-actions list.
        ACTION_NOT_ALLOWED,
        /// @dev Sender identity hash is zero (identity not provided).
        SENDER_IDENTITY_MISSING,
        /// @dev Recipient identity hash is zero (identity not provided).
        RECIPIENT_IDENTITY_MISSING,
        /// @dev Asset is not in the allowed-assets list.
        ASSET_NOT_ALLOWED,
        /// @dev Source chain ID has no configured jurisdiction mapping.
        CHAIN_JURISDICTION_NOT_CONFIGURED,
        /// @dev Source chain jurisdiction is on the blocked list.
        SOURCE_JURISDICTION_BLOCKED,
        /// @dev Destination chain jurisdiction is on the blocked list.
        DESTINATION_JURISDICTION_BLOCKED,
        /// @dev Source chain jurisdiction is not in the allowed list.
        SOURCE_JURISDICTION_NOT_ALLOWED,
        /// @dev Destination chain jurisdiction is not in the allowed list.
        DESTINATION_JURISDICTION_NOT_ALLOWED,
        /// @dev Sender investor classification is below the minimum threshold.
        SENDER_CLASSIFICATION_INSUFFICIENT,
        /// @dev Recipient investor classification is below the minimum threshold.
        RECEIVER_CLASSIFICATION_INSUFFICIENT,
        /// @dev Sender identity hash has no configured investor classification.
        SENDER_NOT_CLASSIFIED,
        /// @dev Recipient identity hash has no configured investor classification.
        RECEIVER_NOT_CLASSIFIED,
        /// @dev Transfer amount exceeds the per-asset maximum.
        TRANSFER_EXCEEDS_MAX_AMOUNT,
        /// @dev Transfer amount would exceed the per-asset holding limit.
        TRANSFER_EXCEEDS_HOLDING_LIMIT,
        /// @dev Intent deadline has passed.
        INTENT_EXPIRED
    }

    /// @notice Investor classification levels.
    /// @dev Ordered from least to most verified. Minimum classification
    ///      thresholds use this ordering (e.g. setting ACCREDITED as
    ///      minimum allows ACCREDITED and INSTITUTIONAL but blocks
    ///      RETAIL and UNKNOWN).
    enum InvestorClassification {
        /// @dev No classification assigned.
        UNKNOWN,
        /// @dev Retail investor (basic KYC).
        RETAIL,
        /// @dev Accredited investor (verified accreditation).
        ACCREDITED,
        /// @dev Institutional investor (entity-level verification).
        INSTITUTIONAL
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Immutable State
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Protocol-wide access manager.
    IProtocolAccessManager private immutable _accessManager;

    /// @dev Cached COMPLIANCE_ROLE identifier.
    bytes32 private immutable _complianceRole;

    // ═══════════════════════════════════════════════════════════════════════
    // Mutable State — Policy Configuration
    // ═══════════════════════════════════════════════════════════════════════

    // ── Versioning ──

    /// @dev Active policy version identifier. Updated when policy changes.
    bytes32 private _currentPolicyVersion;

    /// @dev Set of all previously active policy versions for audit trail.
    mapping(bytes32 version => bool supported) private _supportedPolicyVersions;

    // ── Asset Rules ──

    /// @dev Assets that are approved for transfer through the protocol.
    mapping(bytes32 assetId => bool allowed) private _allowedAssets;

    // ── Jurisdiction Rules ──

    /// @dev Maps a protocol chain ID to a jurisdiction code (e.g. "US", "EU").
    mapping(ChainId chainId => bytes32 jurisdictionCode) private _chainJurisdictions;

    /// @dev Jurisdictions that are explicitly blocked. If non-empty, checked
    ///      before the allowed list (deny-list takes precedence).
    mapping(bytes32 jurisdictionCode => bool blocked) private _blockedJurisdictions;

    /// @dev Jurisdictions that are explicitly allowed. If non-empty, only
    ///      these jurisdictions are permitted. Empty = no allow-list enforcement.
    mapping(bytes32 jurisdictionCode => bool allowed) private _allowedJurisdictions;

    /// @dev Number of entries in the allowed jurisdictions list. Used to
    ///      determine whether the allow-list is active.
    uint256 private _allowedJurisdictionCount;

    // ── Transfer Rules ──

    /// @dev Maximum transfer amount per asset. Zero = no limit.
    mapping(bytes32 assetId => uint256 maxAmount) private _maxTransferAmounts;

    /// @dev Maximum holding per asset (per-transfer cap). Zero = no limit.
    ///      This is a simplified check. Full holding-limit enforcement
    ///      requires running balance queries external to this provider.
    mapping(bytes32 assetId => uint256 maxHolding) private _maxHoldings;

    // ── Investor Rules ──

    /// @dev Assigned classification per identity hash.
    mapping(bytes32 identityHash => InvestorClassification classification) private _investorClassifications;

    /// @dev Minimum classification required for all participants.
    InvestorClassification private _minimumClassification;

    // ── Action Rules ──

    /// @dev Allowed transfer action types. Only these actions are permitted.
    mapping(ProtocolTypes.IntentAction action => bool allowed) private _allowedActions;

    // ═══════════════════════════════════════════════════════════════════════
    // Constructor
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Configures the provider with an access manager.
    /// @dev All addresses MUST be non-zero. No policy rules are active at
    ///      deployment — the contract is inert until a COMPLIANCE_ROLE
    ///      holder configures rules.
    /// @param accessManager Protocol-wide access manager.
    constructor(IProtocolAccessManager accessManager) {
        if (address(accessManager) == address(0)) revert RuleEngine__ZeroAddress();
        _accessManager = accessManager;
        _complianceRole = accessManager.COMPLIANCE_ROLE();
    }

    // ═══════════════════════════════════════════════════════════════════════
    // IERC165
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(ICompliancePolicyProvider).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ICompliancePolicyProvider: Evaluation
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ICompliancePolicyProvider
    /// @dev Runs the full evaluation pipeline. On approval, decisionHash
    ///      = keccak256(abi.encode(intent, policyVersion, "APPROVED")).
    ///      On rejection, decisionHash =
    ///      keccak256(abi.encode(intent, policyVersion, "DENIED")).
    ///      This hash enables off-chain audit verification.
    ///      For on-chain explainability, use evaluateWithReasons().
    function evaluateTransferIntent(
        ProtocolTypes.TransferIntent calldata intent
    ) external view override returns (ProtocolTypes.ComplianceDecision memory decision) {
        ComplianceFailureReason[] memory reasons = new ComplianceFailureReason[](16);
        bool approved = _evaluateAll(intent, reasons);

        decision.result = approved ? ProtocolTypes.ComplianceResult.APPROVED : ProtocolTypes.ComplianceResult.DENIED;
        decision.decisionHash = keccak256(abi.encode(intent, _currentPolicyVersion, approved ? "APPROVED" : "DENIED"));
        decision.evaluatedAt = uint64(block.timestamp);
        decision.expiresAt = intent.expiresAt;
        decision.policyVersion = _currentPolicyVersion;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ICompliancePolicyProvider: Policy Versioning
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ICompliancePolicyProvider
    function currentPolicyVersion() external view override returns (bytes32 policyVersion) {
        return _currentPolicyVersion;
    }

    /// @inheritdoc ICompliancePolicyProvider
    function supportsPolicyVersion(bytes32 policyVersion) external view override returns (bool supported) {
        return _supportedPolicyVersions[policyVersion];
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ICompliancePolicyProvider: Capabilities
    // ═══════════════════════════════════════════════════════════════════════

    /// @inheritdoc ICompliancePolicyProvider
    function getProviderId() external pure override returns (bytes32 providerId) {
        return PROVIDER_ID;
    }

    /// @inheritdoc ICompliancePolicyProvider
    function getCapabilities() external pure override returns (uint256 capabilities) {
        // TRANSFER_EVALUATION    = bit 0
        // POLICY_VERSIONING      = bit 1
        return (1 << 0) | (1 << 1);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration: Policy Version
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Updates the active policy version identifier.
    /// @dev Call this after modifying policy rules so downstream consumers
    ///      can detect configuration changes. The previous version remains
    ///      queryable via supportsPolicyVersion(). Reverts if version is
    ///      bytes32(0).
    /// @param newVersion New policy version identifier (e.g. semantic version
    ///                   or content-addressed digest).
    function setPolicyVersion(bytes32 newVersion) external {
        _onlyComplianceRole();
        if (newVersion == bytes32(0)) revert RuleEngine__EmptyPolicyVersion();
        bytes32 oldVersion = _currentPolicyVersion;
        _currentPolicyVersion = newVersion;
        _supportedPolicyVersions[newVersion] = true;
        emit PolicyVersionUpdated(oldVersion, newVersion);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration: Assets
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Adds or removes an asset from the allowed-assets list.
    /// @param assetId Protocol-level asset identifier.
    /// @param allowed True to allow, false to remove from the allowed list.
    function setAllowedAsset(bytes32 assetId, bool allowed) external {
        _onlyComplianceRole();
        _allowedAssets[assetId] = allowed;
        emit ComplianceConfigUpdated(keccak256(abi.encode("ALLOWED_ASSET", assetId)));
    }

    /// @notice Sets the maximum transfer amount for an asset.
    /// @param assetId   Protocol-level asset identifier.
    /// @param maxAmount Maximum transfer amount in base units. Zero = no limit.
    function setMaxTransferAmount(bytes32 assetId, uint256 maxAmount) external {
        _onlyComplianceRole();
        _maxTransferAmounts[assetId] = maxAmount;
        emit ComplianceConfigUpdated(keccak256(abi.encode("MAX_TRANSFER", assetId)));
    }

    /// @notice Sets the maximum holding limit for an asset (per-transfer cap).
    /// @param assetId   Protocol-level asset identifier.
    /// @param maxHolding Maximum holding amount in base units. Zero = no limit.
    function setMaxHolding(bytes32 assetId, uint256 maxHolding) external {
        _onlyComplianceRole();
        _maxHoldings[assetId] = maxHolding;
        emit ComplianceConfigUpdated(keccak256(abi.encode("MAX_HOLDING", assetId)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration: Jurisdictions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Maps a protocol chain ID to a jurisdiction code.
    /// @param chainId         Protocol-level chain identifier.
    /// @param jurisdictionCode Jurisdiction code (e.g. keccak256("US")).
    ///                         Set to bytes32(0) to clear the mapping.
    function setChainJurisdiction(ChainId chainId, bytes32 jurisdictionCode) external {
        _onlyComplianceRole();
        _chainJurisdictions[chainId] = jurisdictionCode;
        emit ComplianceConfigUpdated(keccak256(abi.encode("CHAIN_JURISDICTION", chainId)));
    }

    /// @notice Adds or removes a jurisdiction from the blocked list.
    /// @dev Blocked jurisdictions are rejected regardless of the allowed list.
    /// @param jurisdictionCode Jurisdiction code.
    /// @param blocked          True to block, false to unblock.
    function setBlockedJurisdiction(bytes32 jurisdictionCode, bool blocked) external {
        _onlyComplianceRole();
        _blockedJurisdictions[jurisdictionCode] = blocked;
        emit ComplianceConfigUpdated(keccak256(abi.encode("BLOCKED_JURISDICTION", jurisdictionCode)));
    }

    /// @notice Adds or removes a jurisdiction from the allowed list.
    /// @dev If non-empty, only these jurisdictions are permitted. An empty
    ///      allowed list means no allow-list enforcement (blocked list still
    ///      applies).
    /// @param jurisdictionCode Jurisdiction code.
    /// @param allowed          True to allow, false to remove.
    function setAllowedJurisdiction(bytes32 jurisdictionCode, bool allowed) external {
        _onlyComplianceRole();
        if (_allowedJurisdictions[jurisdictionCode] == allowed) return;
        _allowedJurisdictions[jurisdictionCode] = allowed;
        if (allowed) {
            _allowedJurisdictionCount++;
        } else {
            _allowedJurisdictionCount--;
        }
        emit ComplianceConfigUpdated(keccak256(abi.encode("ALLOWED_JURISDICTION", jurisdictionCode)));
    }

    /// @notice Returns the number of jurisdictions in the allowed list.
    /// @return count Number of explicitly allowed jurisdictions.
    function getAllowedJurisdictionCount() external view returns (uint256 count) {
        return _allowedJurisdictionCount;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration: Investor Classification
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Sets the investor classification for an identity hash.
    /// @param identityHash     Hash of the participant identity.
    /// @param classification   Investor classification level.
    function setInvestorClassification(bytes32 identityHash, InvestorClassification classification) external {
        _onlyComplianceRole();
        if (uint8(classification) > uint8(InvestorClassification.INSTITUTIONAL)) {
            revert RuleEngine__InvalidClassification(uint8(classification));
        }
        _investorClassifications[identityHash] = classification;
        emit ComplianceConfigUpdated(keccak256(abi.encode("INVESTOR_CLASS", identityHash)));
    }

    /// @notice Sets the minimum classification required for all participants.
    /// @param minClassification Minimum classification. Participants at or
    ///                          below this level are rejected. UNKNOWN (0)
    ///                          means no minimum enforcement.
    function setMinimumClassification(InvestorClassification minClassification) external {
        _onlyComplianceRole();
        if (uint8(minClassification) > uint8(InvestorClassification.INSTITUTIONAL)) {
            revert RuleEngine__InvalidClassification(uint8(minClassification));
        }
        _minimumClassification = minClassification;
        emit ComplianceConfigUpdated(keccak256("MINIMUM_CLASSIFICATION"));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Configuration: Allowed Actions
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Adds or removes an IntentAction from the allowed list.
    /// @dev An empty allowed-actions list means "deny all" — every
    ///      IntentAction will be rejected. At least one action must be
    ///      explicitly allowed for any transfer to succeed.
    /// @param action  The intent action type.
    /// @param allowed True to allow, false to disallow.
    function setAllowedAction(ProtocolTypes.IntentAction action, bool allowed) external {
        _onlyComplianceRole();
        _allowedActions[action] = allowed;
        emit ComplianceConfigUpdated(keccak256(abi.encode("ALLOWED_ACTION", action)));
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Public Supplementary: Explainability
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Evaluates a transfer intent and returns both the compliance
    ///         decision and the full list of failure reasons.
    /// @dev Use this function when detailed explainability is needed (e.g.
    ///      operator review, audit, UI integration). The standard
    ///      `evaluateTransferIntent()` returns only the decision; this
    ///      function adds machine-readable reasons without changing the
    ///      interface contract.
    /// @param intent The transfer intent to evaluate.
    /// @return decision The compliance decision (same as
    ///                  evaluateTransferIntent()).
    /// @return reasons  Array of ComplianceFailureReason values. Empty on
    ///                  approval; non-empty with one entry per failed check
    ///                  on rejection.
    function evaluateWithReasons(
        ProtocolTypes.TransferIntent calldata intent
    ) external view returns (ProtocolTypes.ComplianceDecision memory decision, ComplianceFailureReason[] memory reasons) {
        reasons = new ComplianceFailureReason[](16);
        bool approved = _evaluateAll(intent, reasons);

        // Resize the array down to the actual number of reasons.
        uint256 count;
        for (uint256 i; i < 16; ++i) {
            if (reasons[i] != ComplianceFailureReason.NONE) {
                count++;
            }
        }
        assembly {
            mstore(reasons, count)
        }

        decision.result = approved ? ProtocolTypes.ComplianceResult.APPROVED : ProtocolTypes.ComplianceResult.DENIED;
        decision.decisionHash = keccak256(abi.encode(intent, _currentPolicyVersion, approved ? "APPROVED" : "DENIED"));
        decision.evaluatedAt = uint64(block.timestamp);
        decision.expiresAt = intent.expiresAt;
        decision.policyVersion = _currentPolicyVersion;
    }

    /// @notice Returns the investor classification for a given identity hash.
    /// @param identityHash Hash of the participant identity.
    /// @return classification The assigned classification (UNKNOWN if not set).
    function getInvestorClassification(bytes32 identityHash) external view returns (InvestorClassification classification) {
        return _investorClassifications[identityHash];
    }

    /// @notice Returns whether an asset is in the allowed list.
    /// @param assetId Protocol-level asset identifier.
    /// @return allowed True if the asset is allowed.
    function isAssetAllowed(bytes32 assetId) external view returns (bool allowed) {
        return _allowedAssets[assetId];
    }

    /// @notice Returns the configured jurisdiction for a chain.
    /// @param chainId Protocol-level chain identifier.
    /// @return jurisdictionCode Jurisdiction code, or bytes32(0) if unset.
    function getChainJurisdiction(ChainId chainId) external view returns (bytes32 jurisdictionCode) {
        return _chainJurisdictions[chainId];
    }

    /// @notice Returns whether a jurisdiction is blocked.
    /// @param jurisdictionCode Jurisdiction code.
    /// @return blocked True if the jurisdiction is on the blocked list.
    function isJurisdictionBlocked(bytes32 jurisdictionCode) external view returns (bool blocked) {
        return _blockedJurisdictions[jurisdictionCode];
    }

    /// @notice Returns whether a jurisdiction is in the allowed list.
    /// @param jurisdictionCode Jurisdiction code.
    /// @return allowed True if the jurisdiction is on the allowed list.
    function isJurisdictionAllowed(bytes32 jurisdictionCode) external view returns (bool allowed) {
        return _allowedJurisdictions[jurisdictionCode];
    }

    /// @notice Returns the minimum classification threshold.
    /// @return minClassification The minimum InvestorClassification required.
    function getMinimumClassification() external view returns (InvestorClassification minClassification) {
        return _minimumClassification;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Evaluation Pipeline
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Runs all evaluation helpers and populates the reasons array.
    ///      Returns true if all checks passed, false otherwise.
    ///      The reasons array must be pre-allocated to 16 slots.
    ///      NONE entries are skipped by the caller.
    function _evaluateAll(
        ProtocolTypes.TransferIntent calldata intent,
        ComplianceFailureReason[] memory reasons
    ) private view returns (bool approved) {
        uint256 idx;
        bool result;

        // 1. Action type
        (result, reasons[idx]) = _evaluateAction(intent.action);
        if (!result) idx++;

        // 2. Sender identity
        (result, reasons[idx]) = _evaluateSenderIdentity(intent.senderIdentityHash);
        if (!result) idx++;

        // 3. Recipient identity
        (result, reasons[idx]) = _evaluateRecipientIdentity(intent.recipientIdentityHash);
        if (!result) idx++;

        // 4. Asset
        (result, reasons[idx]) = _evaluateAsset(intent.assetId);
        if (!result) idx++;

        // 5. Jurisdiction
        (result, reasons[idx]) = _evaluateJurisdictions(intent.sourceChainId, intent.destinationChainId);
        if (!result) idx++;

        // 6. Investor classification (sender)
        (result, reasons[idx]) = _evaluateInvestorClassification(intent.senderIdentityHash, true);
        if (!result) idx++;

        // 7. Investor classification (recipient)
        (result, reasons[idx]) = _evaluateInvestorClassification(intent.recipientIdentityHash, false);
        if (!result) idx++;

        // 8. Transfer amount
        (result, reasons[idx]) = _evaluateTransferLimit(intent.assetId, intent.amount);
        if (!result) idx++;

        // 9. Holding limit
        (result, reasons[idx]) = _evaluateHoldingLimit(intent.assetId, intent.amount);
        if (!result) idx++;

        // 10. Time validity
        (result, reasons[idx]) = _evaluateTimeValidity(intent.expiresAt);
        if (!result) idx++;

        // If no failures recorded, all checks passed.
        return idx == 0;
    }

    /// @dev Checks that the IntentAction is in the allowed list.
    ///      If no actions have been configured, all actions are rejected.
    function _evaluateAction(ProtocolTypes.IntentAction action) private view returns (bool, ComplianceFailureReason) {
        if (_allowedActions[action]) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.ACTION_NOT_ALLOWED);
    }

    /// @dev Checks that the sender identity hash is non-zero.
    function _evaluateSenderIdentity(bytes32 identityHash) private pure returns (bool, ComplianceFailureReason) {
        if (identityHash != bytes32(0)) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.SENDER_IDENTITY_MISSING);
    }

    /// @dev Checks that the recipient identity hash is non-zero.
    function _evaluateRecipientIdentity(bytes32 identityHash) private pure returns (bool, ComplianceFailureReason) {
        if (identityHash != bytes32(0)) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.RECIPIENT_IDENTITY_MISSING);
    }

    /// @dev Checks that the asset is in the allowed list.
    function _evaluateAsset(bytes32 assetId) private view returns (bool, ComplianceFailureReason) {
        if (_allowedAssets[assetId]) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.ASSET_NOT_ALLOWED);
    }

    /// @dev Evaluates jurisdiction compatibility for the source and destination
    ///      chains. Both chains must have configured jurisdictions. Blocked
    ///      jurisdictions are always rejected. If the allowed list is non-empty,
    ///      both jurisdictions must be on it.
    function _evaluateJurisdictions(ChainId sourceChain, ChainId destChain) private view returns (bool, ComplianceFailureReason) {
        bytes32 sourceJurisdiction = _chainJurisdictions[sourceChain];
        bytes32 destJurisdiction = _chainJurisdictions[destChain];

        if (sourceJurisdiction == bytes32(0)) {
            return (false, ComplianceFailureReason.CHAIN_JURISDICTION_NOT_CONFIGURED);
        }
        if (destJurisdiction == bytes32(0)) {
            return (false, ComplianceFailureReason.CHAIN_JURISDICTION_NOT_CONFIGURED);
        }

        // Deny-list: blocked jurisdictions are always rejected.
        if (_blockedJurisdictions[sourceJurisdiction]) {
            return (false, ComplianceFailureReason.SOURCE_JURISDICTION_BLOCKED);
        }
        if (_blockedJurisdictions[destJurisdiction]) {
            return (false, ComplianceFailureReason.DESTINATION_JURISDICTION_BLOCKED);
        }

        // Allow-list: if non-empty, both must be in the allowed list.
        if (_allowedJurisdictionCount > 0) {
            if (!_allowedJurisdictions[sourceJurisdiction]) {
                return (false, ComplianceFailureReason.SOURCE_JURISDICTION_NOT_ALLOWED);
            }
            if (!_allowedJurisdictions[destJurisdiction]) {
                return (false, ComplianceFailureReason.DESTINATION_JURISDICTION_NOT_ALLOWED);
            }
        }

        return (true, ComplianceFailureReason.NONE);
    }

    /// @dev Evaluates the investor classification for an identity hash.
    ///      The classification must be >= the configured minimum.
    /// @param identityHash Hash of the participant identity.
    /// @param isSender     True if this is the sender, false if the recipient.
    function _evaluateInvestorClassification(bytes32 identityHash, bool isSender) private view returns (bool, ComplianceFailureReason) {
        if (_minimumClassification == InvestorClassification.UNKNOWN) {
            return (true, ComplianceFailureReason.NONE);
        }
        InvestorClassification classification = _investorClassifications[identityHash];
        if (classification == InvestorClassification.UNKNOWN) {
            return (false, isSender ? ComplianceFailureReason.SENDER_NOT_CLASSIFIED : ComplianceFailureReason.RECEIVER_NOT_CLASSIFIED);
        }
        if (uint8(classification) < uint8(_minimumClassification)) {
            return (false, isSender ? ComplianceFailureReason.SENDER_CLASSIFICATION_INSUFFICIENT : ComplianceFailureReason.RECEIVER_CLASSIFICATION_INSUFFICIENT);
        }
        return (true, ComplianceFailureReason.NONE);
    }

    /// @dev Checks that the transfer amount does not exceed the per-asset
    ///      maximum. Zero max = no limit.
    function _evaluateTransferLimit(bytes32 assetId, uint256 amount) private view returns (bool, ComplianceFailureReason) {
        uint256 maxAmount = _maxTransferAmounts[assetId];
        if (maxAmount == 0) return (true, ComplianceFailureReason.NONE);
        if (amount <= maxAmount) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.TRANSFER_EXCEEDS_MAX_AMOUNT);
    }

    /// @dev Checks that the transfer amount does not exceed the per-asset
    ///      holding limit. Zero = no limit. NOTE: This is a per-transfer
    ///      cap, not a running-balance check.
    function _evaluateHoldingLimit(bytes32 assetId, uint256 amount) private view returns (bool, ComplianceFailureReason) {
        uint256 maxHolding = _maxHoldings[assetId];
        if (maxHolding == 0) return (true, ComplianceFailureReason.NONE);
        if (amount <= maxHolding) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.TRANSFER_EXCEEDS_HOLDING_LIMIT);
    }

    /// @dev Checks that the intent has not expired. Zero expiresAt means
    ///      no expiry.
    function _evaluateTimeValidity(uint64 expiresAt) private view returns (bool, ComplianceFailureReason) {
        if (expiresAt == 0) return (true, ComplianceFailureReason.NONE);
        if (expiresAt > block.timestamp) return (true, ComplianceFailureReason.NONE);
        return (false, ComplianceFailureReason.INTENT_EXPIRED);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // Internal: Access Control
    // ═══════════════════════════════════════════════════════════════════════

    /// @dev Reverts if msg.sender does not hold COMPLIANCE_ROLE.
    function _onlyComplianceRole() private view {
        if (!_accessManager.hasRole(_complianceRole, msg.sender)) {
            revert RuleEngine__UnauthorizedRole(msg.sender, _complianceRole);
        }
    }
}
