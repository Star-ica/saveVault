// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./MultiSigVault.sol";

/**
 * @title VaultFactory
 * @author SafeVault Protocol
 * @notice Deploys and indexes MultiSigVault instances on BOT Chain.
 *         Tracks vaults by creator address and by signer membership.
 */
contract VaultFactory {

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Every vault ever created through this factory.
    address[] private _allVaults;

    /// @notice owner → list of vaults they created.
    mapping(address => address[]) private _vaultsByOwner;

    /// @notice signer → list of vaults they are a member of.
    mapping(address => address[]) private _vaultsBySigner;

    /// @notice Quick existence check.
    mapping(address => bool) private _isVault;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event VaultCreated(
        address indexed vault,
        address indexed creator,
        string  name,
        address[] signers,
        uint256 threshold,
        uint256 timestamp
    );

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error EmptySignerList();
    error InvalidThreshold(uint256 threshold, uint256 signerCount);
    error DuplicateSigner(address signer);
    error ZeroAddressSigner();

    // ─────────────────────────────────────────────────────────────────────────
    // Core
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Deploy a new MultiSigVault.
     * @param signers     Ordered list of initial signers. No duplicates, no zero addresses.
     * @param threshold_  Number of approvals required to execute a proposal.
     * @param name        Human-readable vault name (stored on-chain).
     * @param description Short description of the vault's purpose.
     * @return vault      Address of the newly deployed MultiSigVault.
     */
    function createVault(
        address[] calldata signers,
        uint256 threshold_,
        string calldata name,
        string calldata description
    ) external returns (address vault) {
        // ── Validation ───────────────────────────────────────────────────────
        uint256 n = signers.length;
        if (n == 0) revert EmptySignerList();
        if (threshold_ == 0 || threshold_ > n)
            revert InvalidThreshold(threshold_, n);

        // Check for duplicates and zero addresses in a single pass
        for (uint256 i = 0; i < n; i++) {
            if (signers[i] == address(0)) revert ZeroAddressSigner();
            for (uint256 j = i + 1; j < n; j++) {
                if (signers[i] == signers[j]) revert DuplicateSigner(signers[i]);
            }
        }

        // ── Deployment ───────────────────────────────────────────────────────
        MultiSigVault newVault = new MultiSigVault(
            signers,
            threshold_,
            name,
            description,
            msg.sender
        );
        vault = address(newVault);

        // ── Index ────────────────────────────────────────────────────────────
        _allVaults.push(vault);
        _isVault[vault] = true;
        _vaultsByOwner[msg.sender].push(vault);

        for (uint256 i = 0; i < n; i++) {
            _vaultsBySigner[signers[i]].push(vault);
        }

        emit VaultCreated(vault, msg.sender, name, signers, threshold_, block.timestamp);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns all vaults created through this factory.
    function getAllVaults() external view returns (address[] memory) {
        return _allVaults;
    }

    /// @notice Total number of vaults ever created.
    function vaultCount() external view returns (uint256) {
        return _allVaults.length;
    }

    /**
     * @notice Returns all vaults created by a specific owner.
     * @param owner  Creator address to query.
     */
    function getVaultsByOwner(address owner) external view returns (address[] memory) {
        return _vaultsByOwner[owner];
    }

    /**
     * @notice Returns all vaults in which an address is a signer.
     * @dev    This reflects the initial signer list at creation time.
     *         Signer changes via governance proposals are not reflected here;
     *         use SignerRegistry for live membership data.
     * @param signer  Address to query.
     */
    function getVaultsBySigner(address signer) external view returns (address[] memory) {
        return _vaultsBySigner[signer];
    }

    /**
     * @notice Returns whether an address is a vault created by this factory.
     * @param addr  Address to check.
     */
    function isKnownVault(address addr) external view returns (bool) {
        return _isVault[addr];
    }

    /**
     * @notice Returns a paginated slice of all vaults.
     * @param offset  Starting index.
     * @param limit   Maximum number of addresses to return.
     */
    function getVaultsPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory results)
    {
        uint256 total = _allVaults.length;
        if (offset >= total) return new address[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        results = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            results[i - offset] = _allVaults[i];
        }
    }
}
