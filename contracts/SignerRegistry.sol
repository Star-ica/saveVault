// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MultiSigVault.sol";

/**
 * @title SignerRegistry
 * @author SafeVault Protocol
 * @notice Read-only helper that provides live signer membership and threshold data
 *         by querying MultiSigVault contracts directly. Because signer changes go
 *         through on-chain governance proposals inside each vault, this registry
 *         is always accurate — it delegates every query to the vault itself.
 * @dev    No state is duplicated here; all answers come from the live vault state.
 */
contract SignerRegistry {

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error ZeroAddress();

    // ─────────────────────────────────────────────────────────────────────────
    // Signer Queries
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Returns whether an address is a current signer of a vault.
     * @param vault   MultiSigVault contract address.
     * @param signer  Address to check.
     * @return        True if the address is an active signer.
     */
    function isSigner(address vault, address signer) external view returns (bool) {
        if (vault == address(0) || signer == address(0)) revert ZeroAddress();
        return MultiSigVault(payable(vault)).isSigner(signer);
    }

    /**
     * @notice Returns the full list of current signers for a vault.
     * @param vault  MultiSigVault contract address.
     * @return       Array of signer addresses.
     */
    function getSigners(address vault) external view returns (address[] memory) {
        if (vault == address(0)) revert ZeroAddress();
        return MultiSigVault(payable(vault)).getSigners();
    }

    /**
     * @notice Returns the approval threshold for a vault.
     * @param vault  MultiSigVault contract address.
     * @return       Current threshold value.
     */
    function getThreshold(address vault) external view returns (uint256) {
        if (vault == address(0)) revert ZeroAddress();
        return MultiSigVault(payable(vault)).threshold();
    }

    /**
     * @notice Returns signers and threshold for a vault in a single call.
     * @param vault  MultiSigVault contract address.
     * @return signers_    Current signer list.
     * @return threshold_  Current approval threshold.
     */
    function getSignersAndThreshold(address vault)
        external
        view
        returns (address[] memory signers_, uint256 threshold_)
    {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));
        signers_   = v.getSigners();
        threshold_ = v.threshold();
    }

    /**
     * @notice Batch-checks signer membership across multiple vaults.
     * @param vaults  Array of vault addresses.
     * @param signer  Signer address to check.
     * @return        Boolean array; results[i] == true when signer is in vaults[i].
     */
    function batchIsSigner(address[] calldata vaults, address signer)
        external
        view
        returns (bool[] memory)
    {
        bool[] memory results = new bool[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] != address(0)) {
                results[i] = MultiSigVault(payable(vaults[i])).isSigner(signer);
            }
        }
        return results;
    }

    /**
     * @notice Returns the number of signers for a vault.
     * @param vault  MultiSigVault contract address.
     * @return       Number of active signers.
     */
    function signerCount(address vault) external view returns (uint256) {
        if (vault == address(0)) revert ZeroAddress();
        return MultiSigVault(payable(vault)).getSigners().length;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Vault Summary
    // ─────────────────────────────────────────────────────────────────────────

    struct VaultSummary {
        address vault;
        string  name;
        address[] signers;
        uint256 threshold;
        uint256 botBalance;
        uint256 proposalCount;
        bool    paused;
    }

    /**
     * @notice Returns a compact summary of a vault's current state.
     * @param vault  MultiSigVault contract address.
     * @return       Packed VaultSummary struct.
     */
    function getVaultSummary(address vault)
        external
        view
        returns (VaultSummary memory)
    {
        if (vault == address(0)) revert ZeroAddress();
        MultiSigVault v = MultiSigVault(payable(vault));
        return VaultSummary({
            vault:         vault,
            name:          v.vaultName(),
            signers:       v.getSigners(),
            threshold:     v.threshold(),
            botBalance:    vault.balance,
            proposalCount: v.proposalCount(),
            paused:        v.paused()
        });
    }

    /**
     * @notice Batch-fetches summaries for multiple vaults.
     * @param vaults  Array of vault addresses.
     * @return        Array of VaultSummary structs in the same order.
     */
    function batchGetSummaries(address[] calldata vaults)
        external
        view
        returns (VaultSummary[] memory)
    {
        VaultSummary[] memory summaries = new VaultSummary[](vaults.length);
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] != address(0)) {
                MultiSigVault v = MultiSigVault(payable(vaults[i]));
                summaries[i] = VaultSummary({
                    vault:         vaults[i],
                    name:          v.vaultName(),
                    signers:       v.getSigners(),
                    threshold:     v.threshold(),
                    botBalance:    vaults[i].balance,
                    proposalCount: v.proposalCount(),
                    paused:        v.paused()
                });
            }
        }
        return summaries;
    }
}
