// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MultiSigVault.sol";

/**
 * @title ProposalManager
 * @author SafeVault Protocol
 * @notice Read-only query helper for proposal data across MultiSigVault instances.
 *         Provides paginated listings, pending approval queues per signer, and
 *         per-signer vote status. Contains no mutable state.
 */
contract ProposalManager {

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    struct ProposalWithVoteStatus {
        MultiSigVault.Proposal proposal;
        bool   hasVoted;
        bool   voteValue;   // only meaningful when hasVoted == true
        bool   canExecute;  // approvals >= threshold && !executed && !cancelled
        bool   isExpired;   // deadline passed
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Paginated Proposal Queries
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns a paginated list of proposals from a vault.
     * @param vault   MultiSigVault address.
     * @param offset  Starting proposal index.
     * @param limit   Maximum proposals to return.
     * @return        Array of Proposal structs.
     */
    function getProposals(
        address vault,
        uint256 offset,
        uint256 limit
    ) external view returns (MultiSigVault.Proposal[] memory) {
        if (vault == address(0)) revert ZeroAddress();
        return MultiSigVault(payable(vault)).getProposals(offset, limit);
    }

    /**
     * @notice Returns pending (not yet executed or cancelled, within deadline)
     *         proposals for a vault, with vote status enrichment for a given signer.
     * @param vault   MultiSigVault address.
     * @param signer  Signer address to check vote status for.
     * @param offset  Starting proposal index.
     * @param limit   Maximum proposals to scan.
     * @return        Array of ProposalWithVoteStatus; only pending proposals included.
     */
    function getPendingProposals(
        address vault,
        address signer,
        uint256 offset,
        uint256 limit
    ) external view returns (ProposalWithVoteStatus[] memory) {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));

        MultiSigVault.Proposal[] memory all = v.getProposals(offset, limit);
        uint256 threshold = v.threshold();

        // Count how many are pending
        uint256 pendingCount = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_isPending(all[i])) pendingCount++;
        }

        ProposalWithVoteStatus[] memory results = new ProposalWithVoteStatus[](pendingCount);
        uint256 ri = 0;
        for (uint256 i = 0; i < all.length; i++) {
            MultiSigVault.Proposal memory p = all[i];
            if (!_isPending(p)) continue;

            bool voted     = signer != address(0) ? v.hasVoted(p.id, signer) : false;
            bool voteValue = voted ? v.getVote(p.id, signer) : false;
            bool expired   = p.deadline != 0 && block.timestamp > p.deadline;

            results[ri++] = ProposalWithVoteStatus({
                proposal:   p,
                hasVoted:   voted,
                voteValue:  voteValue,
                canExecute: p.approvals >= threshold && !p.executed && !p.cancelled && !expired,
                isExpired:  expired
            });
        }
        return results;
    }

    /**
     * @notice Returns all proposals on which a signer has not yet voted,
     *         limited to pending proposals.
     * @param vault   MultiSigVault address.
     * @param signer  Signer address.
     * @param offset  Starting proposal index.
     * @param limit   Maximum proposals to scan.
     * @return        Array of Proposal structs awaiting this signer's vote.
     */
    function getProposalsAwaitingSignerVote(
        address vault,
        address signer,
        uint256 offset,
        uint256 limit
    ) external view returns (MultiSigVault.Proposal[] memory) {
        if (vault == address(0) || signer == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));

        // Signer must be active; non-signers trivially have no pending votes
        if (!v.isSigner(signer)) return new MultiSigVault.Proposal[](0);

        MultiSigVault.Proposal[] memory all = v.getProposals(offset, limit);

        // Count
        uint256 cnt = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_isPending(all[i]) && !v.hasVoted(all[i].id, signer)) cnt++;
        }

        MultiSigVault.Proposal[] memory results = new MultiSigVault.Proposal[](cnt);
        uint256 ri = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (_isPending(all[i]) && !v.hasVoted(all[i].id, signer)) {
                results[ri++] = all[i];
            }
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Single Proposal Vote Status
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns vote status for a single proposal, enriched for a signer.
     * @param vault       MultiSigVault address.
     * @param proposalId  Proposal ID.
     * @param signer      Signer address.
     * @return            ProposalWithVoteStatus struct.
     */
    function getProposalStatus(
        address vault,
        uint256 proposalId,
        address signer
    ) external view returns (ProposalWithVoteStatus memory) {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));

        MultiSigVault.Proposal memory p  = v.getProposal(proposalId);
        uint256 threshold                = v.threshold();
        bool voted      = signer != address(0) ? v.hasVoted(proposalId, signer) : false;
        bool voteValue  = voted ? v.getVote(proposalId, signer) : false;
        bool expired    = p.deadline != 0 && block.timestamp > p.deadline;

        return ProposalWithVoteStatus({
            proposal:   p,
            hasVoted:   voted,
            voteValue:  voteValue,
            canExecute: p.approvals >= threshold && !p.executed && !p.cancelled && !expired,
            isExpired:  expired
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Executed / History
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns executed proposals (transaction history) for a vault.
     * @param vault   MultiSigVault address.
     * @param offset  Starting proposal index.
     * @param limit   Maximum proposals to scan.
     * @return        Array of executed Proposal structs.
     */
    function getExecutedProposals(
        address vault,
        uint256 offset,
        uint256 limit
    ) external view returns (MultiSigVault.Proposal[] memory) {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));
        MultiSigVault.Proposal[] memory all = v.getProposals(offset, limit);

        uint256 cnt = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].executed) cnt++;
        }

        MultiSigVault.Proposal[] memory results = new MultiSigVault.Proposal[](cnt);
        uint256 ri = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].executed) results[ri++] = all[i];
        }
        return results;
    }

    /**
     * @notice Returns cancelled proposals for a vault.
     * @param vault   MultiSigVault address.
     * @param offset  Starting proposal index.
     * @param limit   Maximum proposals to scan.
     * @return        Array of cancelled Proposal structs.
     */
    function getCancelledProposals(
        address vault,
        uint256 offset,
        uint256 limit
    ) external view returns (MultiSigVault.Proposal[] memory) {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));
        MultiSigVault.Proposal[] memory all = v.getProposals(offset, limit);

        uint256 cnt = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].cancelled) cnt++;
        }

        MultiSigVault.Proposal[] memory results = new MultiSigVault.Proposal[](cnt);
        uint256 ri = 0;
        for (uint256 i = 0; i < all.length; i++) {
            if (all[i].cancelled) results[ri++] = all[i];
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Approval Matrix
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns vote status for every signer on a given proposal.
     * @param vault       MultiSigVault address.
     * @param proposalId  Proposal ID to inspect.
     * @return signers_   Current signer list.
     * @return voted_     Whether each signer has voted (parallel array).
     * @return approved_  Whether each signer approved (only valid when voted_[i] == true).
     */
    function getApprovalMatrix(
        address vault,
        uint256 proposalId
    ) external view returns (
        address[] memory signers_,
        bool[]    memory voted_,
        bool[]    memory approved_
    ) {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));

        signers_  = v.getSigners();
        voted_    = new bool[](signers_.length);
        approved_ = new bool[](signers_.length);

        for (uint256 i = 0; i < signers_.length; i++) {
            voted_[i]    = v.hasVoted(proposalId, signers_[i]);
            approved_[i] = voted_[i] ? v.getVote(proposalId, signers_[i]) : false;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _isPending(MultiSigVault.Proposal memory p) private view returns (bool) {
        if (p.executed || p.cancelled) return false;
        if (p.deadline != 0 && block.timestamp > p.deadline) return false;
        return true;
    }
}
