// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title MultiSigVault
 * @author SafeVault Protocol
 * @notice A multisignature treasury vault supporting native BOT and ERC-20 assets.
 *         All signer changes and threshold updates must go through the proposal flow —
 *         there is no privileged backdoor.
 * @dev Inherits ReentrancyGuard, Pausable, and Ownable from OpenZeppelin v5.
 */
contract MultiSigVault is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;

    // ─────────────────────────────────────────────────────────────────────────
    // Types
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Supported proposal categories.
    enum ProposalType {
        Transfer,          // Send native BOT or ERC-20 token
        ContractCall,      // Arbitrary call with optional value
        AddSigner,         // Governance: add a new signer
        RemoveSigner,      // Governance: remove an existing signer
        ChangeThreshold    // Governance: update approval threshold
    }

    /// @notice Full state of a proposal.
    struct Proposal {
        uint256 id;
        address proposer;
        address to;
        uint256 value;          // Native BOT amount (wei)
        address token;          // address(0) = native BOT transfer
        uint256 tokenAmount;    // ERC-20 amount (token decimals)
        bytes data;             // Calldata for ContractCall proposals
        string description;
        uint256 approvals;
        uint256 rejections;
        bool executed;
        bool cancelled;
        uint256 createdAt;
        uint256 deadline;       // Unix timestamp; 0 = no deadline
        ProposalType kind;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    string public vaultName;
    string public vaultDescription;

    address[] private _signers;
    mapping(address => bool) private _isSigner;
    uint256 public threshold;

    uint256 private _nextProposalId;
    mapping(uint256 => Proposal) private _proposals;

    /// @notice proposalId → signer → voted
    mapping(uint256 => mapping(address => bool)) private _voted;
    /// @notice proposalId → signer → approved (true) or rejected (false)
    mapping(uint256 => mapping(address => bool)) private _voteValue;

    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    event BOTDeposited(address indexed sender, uint256 amount);
    event TokenDeposited(address indexed sender, address indexed token, uint256 amount);
    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed proposer,
        ProposalType indexed kind,
        address to,
        uint256 value,
        address token,
        uint256 tokenAmount,
        string description,
        uint256 deadline
    );
    event ProposalApproved(uint256 indexed proposalId, address indexed signer);
    event ProposalRejected(uint256 indexed proposalId, address indexed signer);
    event ProposalExecuted(uint256 indexed proposalId, address indexed executor);
    event ProposalCancelled(uint256 indexed proposalId, address indexed cancelledBy);
    event SignerAdded(address indexed signer);
    event SignerRemoved(address indexed signer);
    event ThresholdChanged(uint256 oldThreshold, uint256 newThreshold);
    event VaultPaused(address indexed by);
    event VaultUnpaused(address indexed by);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    error NotSigner(address caller);
    error AlreadyVoted(uint256 proposalId, address signer);
    error ProposalNotFound(uint256 proposalId);
    error ProposalAlreadyExecuted(uint256 proposalId);
    error ProposalAlreadyCancelled(uint256 proposalId);
    error ProposalDeadlinePassed(uint256 proposalId);
    error InsufficientApprovals(uint256 have, uint256 need);
    error InsufficientBalance(uint256 have, uint256 need);
    error CallFailed();
    error InvalidThreshold(uint256 threshold, uint256 signerCount);
    error SignerAlreadyExists(address signer);
    error SignerDoesNotExist(address signer);
    error NotProposerOrVault(address caller);
    error ZeroAddress();
    error EmptySignerList();

    // ─────────────────────────────────────────────────────────────────────────
    // Modifiers
    // ─────────────────────────────────────────────────────────────────────────

    modifier onlySigner() {
        if (!_isSigner[msg.sender]) revert NotSigner(msg.sender);
        _;
    }

    modifier proposalExists(uint256 id) {
        if (id >= _nextProposalId) revert ProposalNotFound(id);
        _;
    }

    modifier proposalActive(uint256 id) {
        Proposal storage p = _proposals[id];
        if (p.executed) revert ProposalAlreadyExecuted(id);
        if (p.cancelled) revert ProposalAlreadyCancelled(id);
        if (p.deadline != 0 && block.timestamp > p.deadline) revert ProposalDeadlinePassed(id);
        _;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Constructor
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @param signers_      Initial list of signers (must be non-empty, no duplicates).
     * @param threshold_    Number of approvals required (1 ≤ threshold ≤ signers.length).
     * @param name_         Human-readable vault name.
     * @param description_  Short description of the vault's purpose.
     * @param creator       Address that deployed the vault (becomes Ownable owner).
     */
    constructor(
        address[] memory signers_,
        uint256 threshold_,
        string memory name_,
        string memory description_,
        address creator
    ) Ownable(creator) {
        if (signers_.length == 0) revert EmptySignerList();
        if (threshold_ == 0 || threshold_ > signers_.length)
            revert InvalidThreshold(threshold_, signers_.length);

        for (uint256 i = 0; i < signers_.length; i++) {
            address s = signers_[i];
            if (s == address(0)) revert ZeroAddress();
            if (_isSigner[s]) revert SignerAlreadyExists(s);
            _isSigner[s] = true;
            _signers.push(s);
        }

        threshold = threshold_;
        vaultName = name_;
        vaultDescription = description_;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Deposits
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Deposit native BOT into the vault.
    receive() external payable {
        emit BOTDeposited(msg.sender, msg.value);
    }

    /// @notice Explicit BOT deposit entry point.
    function depositBOT() external payable {
        emit BOTDeposited(msg.sender, msg.value);
    }

    /**
     * @notice Deposit ERC-20 tokens into the vault.
     * @param token  ERC-20 contract address.
     * @param amount Amount of tokens to deposit (token decimals).
     */
    function depositToken(address token, uint256 amount) external nonReentrant whenNotPaused {
        if (token == address(0)) revert ZeroAddress();
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit TokenDeposited(msg.sender, token, amount);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Proposal Creation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Create a new proposal.
     * @param to           Recipient or target contract address.
     * @param value        Native BOT amount in wei (for Transfer/ContractCall).
     * @param token        ERC-20 token address; address(0) for native BOT.
     * @param tokenAmount  ERC-20 token amount; ignored when token == address(0).
     * @param data         Calldata; used for ContractCall proposals.
     * @param description  Human-readable description.
     * @param deadline     Unix timestamp expiry; 0 for no expiry.
     * @param kind         Proposal type enum.
     * @return proposalId  ID of the newly created proposal.
     */
    function propose(
        address to,
        uint256 value,
        address token,
        uint256 tokenAmount,
        bytes calldata data,
        string calldata description,
        uint256 deadline,
        ProposalType kind
    ) external onlySigner whenNotPaused returns (uint256 proposalId) {
        if (to == address(0) && kind != ProposalType.ChangeThreshold) revert ZeroAddress();
        if (deadline != 0 && deadline <= block.timestamp) revert ProposalDeadlinePassed(0);

        proposalId = _nextProposalId++;
        Proposal storage p = _proposals[proposalId];
        p.id          = proposalId;
        p.proposer    = msg.sender;
        p.to          = to;
        p.value       = value;
        p.token       = token;
        p.tokenAmount = tokenAmount;
        p.data        = data;
        p.description = description;
        p.approvals   = 0;
        p.rejections  = 0;
        p.executed    = false;
        p.cancelled   = false;
        p.createdAt   = block.timestamp;
        p.deadline    = deadline;
        p.kind        = kind;

        emit ProposalCreated(
            proposalId,
            msg.sender,
            kind,
            to,
            value,
            token,
            tokenAmount,
            description,
            deadline
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Voting
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Approve a proposal.
     * @param proposalId  ID of the proposal to approve.
     */
    function approve(uint256 proposalId)
        external
        onlySigner
        proposalExists(proposalId)
        proposalActive(proposalId)
        whenNotPaused
    {
        if (_voted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        _voted[proposalId][msg.sender]      = true;
        _voteValue[proposalId][msg.sender]  = true;
        _proposals[proposalId].approvals   += 1;

        emit ProposalApproved(proposalId, msg.sender);
    }

    /**
     * @notice Reject a proposal.
     * @param proposalId  ID of the proposal to reject.
     */
    function reject(uint256 proposalId)
        external
        onlySigner
        proposalExists(proposalId)
        proposalActive(proposalId)
        whenNotPaused
    {
        if (_voted[proposalId][msg.sender]) revert AlreadyVoted(proposalId, msg.sender);

        _voted[proposalId][msg.sender]      = true;
        _voteValue[proposalId][msg.sender]  = false;
        _proposals[proposalId].rejections  += 1;

        emit ProposalRejected(proposalId, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Execution
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Execute a proposal that has reached the approval threshold.
     * @dev    Follows checks-effects-interactions pattern. ReentrancyGuard active.
     * @param proposalId  ID of the proposal to execute.
     */
    function execute(uint256 proposalId)
        external
        nonReentrant
        onlySigner
        proposalExists(proposalId)
        proposalActive(proposalId)
        whenNotPaused
    {
        Proposal storage p = _proposals[proposalId];
        if (p.approvals < threshold)
            revert InsufficientApprovals(p.approvals, threshold);

        // ── Effects ──────────────────────────────────────────────────────────
        p.executed = true;

        // ── Interactions ─────────────────────────────────────────────────────
        if (p.kind == ProposalType.Transfer) {
            _executeTransfer(p);
        } else if (p.kind == ProposalType.ContractCall) {
            _executeContractCall(p);
        } else if (p.kind == ProposalType.AddSigner) {
            _executeAddSigner(p.to);
        } else if (p.kind == ProposalType.RemoveSigner) {
            _executeRemoveSigner(p.to);
        } else if (p.kind == ProposalType.ChangeThreshold) {
            _executeChangeThreshold(p.value);
        }

        emit ProposalExecuted(proposalId, msg.sender);
    }

    /**
     * @notice Cancel a proposal before execution.
     * @dev    Only the original proposer or the vault itself (via another proposal) can cancel.
     * @param proposalId  ID of the proposal to cancel.
     */
    function cancel(uint256 proposalId)
        external
        proposalExists(proposalId)
        proposalActive(proposalId)
        whenNotPaused
    {
        Proposal storage p = _proposals[proposalId];
        if (msg.sender != p.proposer && msg.sender != address(this))
            revert NotProposerOrVault(msg.sender);

        p.cancelled = true;
        emit ProposalCancelled(proposalId, msg.sender);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Pause (requires a proposal of kind ContractCall targeting this contract)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @notice Pause vault operations. Can only be triggered via proposal execution.
     */
    function pauseVault() external {
        require(msg.sender == address(this), "MultiSigVault: only via proposal");
        _pause();
        emit VaultPaused(tx.origin);
    }

    /**
     * @notice Unpause vault operations. Can only be triggered via proposal execution.
     */
    function unpauseVault() external {
        require(msg.sender == address(this), "MultiSigVault: only via proposal");
        _unpause();
        emit VaultUnpaused(tx.origin);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Views
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Returns the vault's native BOT balance.
    function getBalance() external view returns (uint256) {
        return address(this).balance;
    }

    /**
     * @notice Returns the vault's balance of a given ERC-20 token.
     * @param token  ERC-20 contract address.
     */
    function getTokenBalance(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Returns the current list of signers.
    function getSigners() external view returns (address[] memory) {
        return _signers;
    }

    /// @notice Returns whether an address is a current signer.
    function isSigner(address addr) external view returns (bool) {
        return _isSigner[addr];
    }

    /// @notice Returns the total number of proposals ever created.
    function proposalCount() external view returns (uint256) {
        return _nextProposalId;
    }

    /**
     * @notice Returns full details for a single proposal.
     * @param proposalId  Proposal ID to query.
     */
    function getProposal(uint256 proposalId)
        external
        view
        proposalExists(proposalId)
        returns (Proposal memory)
    {
        return _proposals[proposalId];
    }

    /**
     * @notice Returns whether a signer has voted on a proposal.
     * @param proposalId  Proposal ID.
     * @param signer      Signer address.
     */
    function hasVoted(uint256 proposalId, address signer) external view returns (bool) {
        return _voted[proposalId][signer];
    }

    /**
     * @notice Returns how a signer voted (true = approved, false = rejected).
     * @dev    Reverts implicitly to zero (false) if signer has not voted.
     * @param proposalId  Proposal ID.
     * @param signer      Signer address.
     */
    function getVote(uint256 proposalId, address signer) external view returns (bool) {
        return _voteValue[proposalId][signer];
    }

    /**
     * @notice Returns a paginated slice of proposals.
     * @param offset  Starting index.
     * @param limit   Maximum number of proposals to return.
     */
    function getProposals(uint256 offset, uint256 limit)
        external
        view
        returns (Proposal[] memory results)
    {
        uint256 total = _nextProposalId;
        if (offset >= total) return new Proposal[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        results = new Proposal[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            results[i - offset] = _proposals[i];
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Internal execution helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _executeTransfer(Proposal storage p) private {
        if (p.token == address(0)) {
            // Native BOT transfer
            if (address(this).balance < p.value)
                revert InsufficientBalance(address(this).balance, p.value);
            (bool ok, ) = p.to.call{value: p.value}("");
            if (!ok) revert CallFailed();
        } else {
            // ERC-20 token transfer
            IERC20(p.token).safeTransfer(p.to, p.tokenAmount);
        }
    }

    function _executeContractCall(Proposal storage p) private {
        if (address(this).balance < p.value)
            revert InsufficientBalance(address(this).balance, p.value);
        (bool ok, ) = p.to.call{value: p.value}(p.data);
        if (!ok) revert CallFailed();
    }

    function _executeAddSigner(address newSigner) private {
        if (newSigner == address(0)) revert ZeroAddress();
        if (_isSigner[newSigner]) revert SignerAlreadyExists(newSigner);
        _isSigner[newSigner] = true;
        _signers.push(newSigner);
        emit SignerAdded(newSigner);
    }

    function _executeRemoveSigner(address signer) private {
        if (!_isSigner[signer]) revert SignerDoesNotExist(signer);
        // Ensure threshold remains valid after removal
        uint256 newCount = _signers.length - 1;
        if (newCount == 0) revert EmptySignerList();
        if (threshold > newCount) revert InvalidThreshold(threshold, newCount);

        _isSigner[signer] = false;
        for (uint256 i = 0; i < _signers.length; i++) {
            if (_signers[i] == signer) {
                _signers[i] = _signers[_signers.length - 1];
                _signers.pop();
                break;
            }
        }
        emit SignerRemoved(signer);
    }

    function _executeChangeThreshold(uint256 newThreshold) private {
        if (newThreshold == 0 || newThreshold > _signers.length)
            revert InvalidThreshold(newThreshold, _signers.length);
        uint256 old = threshold;
        threshold = newThreshold;
        emit ThresholdChanged(old, newThreshold);
    }
}
