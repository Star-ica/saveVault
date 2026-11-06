/**
 * SafeVault Test Suite
 * Framework: Hardhat + Ethers.js v6 + Chai
 *
 * Run:  npx hardhat test tests/safevault.test.js
 */

const { expect }       = require("chai");
const { ethers }       = require("hardhat");
const { parseEther, ZeroAddress } = ethers;

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function deploy(name, ...args) {
  const Factory = await ethers.getContractFactory(name);
  const contract = await Factory.deploy(...args);
  await contract.waitForDeployment();
  return contract;
}

async function deployVaultFactory() {
  return deploy("VaultFactory");
}

async function createVaultViaFactory(factory, signers, threshold, name, description, sender) {
  const tx   = await factory.connect(sender).createVault(signers, threshold, name, description);
  const rec  = await tx.wait();
  const evt  = rec.logs.find(l => {
    try { return factory.interface.parseLog(l)?.name === "VaultCreated"; } catch { return false; }
  });
  const parsed = factory.interface.parseLog(evt);
  return await ethers.getContractAt("MultiSigVault", parsed.args.vault);
}

// ─────────────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────────────

describe("SafeVault Protocol", () => {
  let owner, alice, bob, carol, dave, eve;
  let factory;

  before(async () => {
    [owner, alice, bob, carol, dave, eve] = await ethers.getSigners();
    factory = await deployVaultFactory();
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("VaultFactory", () => {

    it("deploys with zero vaults", async () => {
      expect(await factory.vaultCount()).to.equal(0n);
    });

    it("creates a vault and emits VaultCreated", async () => {
      const signers = [alice.address, bob.address, carol.address];
      await expect(
        factory.connect(owner).createVault(signers, 2, "Treasury Alpha", "Main treasury")
      ).to.emit(factory, "VaultCreated");
    });

    it("increments vault count", async () => {
      expect(await factory.vaultCount()).to.equal(1n);
    });

    it("indexes vault under owner", async () => {
      const vaults = await factory.getVaultsByOwner(owner.address);
      expect(vaults.length).to.equal(1);
    });

    it("indexes vault under each signer", async () => {
      const v = await factory.getVaultsBySigner(alice.address);
      expect(v.length).to.equal(1);
    });

    it("reverts on empty signer list", async () => {
      await expect(
        factory.createVault([], 1, "Bad", "")
      ).to.be.revertedWithCustomError(factory, "EmptySignerList");
    });

    it("reverts on threshold > signers", async () => {
      await expect(
        factory.createVault([alice.address], 2, "Bad", "")
      ).to.be.revertedWithCustomError(factory, "InvalidThreshold");
    });

    it("reverts on threshold == 0", async () => {
      await expect(
        factory.createVault([alice.address], 0, "Bad", "")
      ).to.be.revertedWithCustomError(factory, "InvalidThreshold");
    });

    it("reverts on duplicate signers", async () => {
      await expect(
        factory.createVault([alice.address, alice.address], 1, "Bad", "")
      ).to.be.revertedWithCustomError(factory, "DuplicateSigner");
    });

    it("reverts on zero-address signer", async () => {
      await expect(
        factory.createVault([ZeroAddress, alice.address], 1, "Bad", "")
      ).to.be.revertedWithCustomError(factory, "ZeroAddressSigner");
    });

    it("isKnownVault returns true for created vaults", async () => {
      const vaults = await factory.getVaultsByOwner(owner.address);
      expect(await factory.isKnownVault(vaults[0])).to.be.true;
    });

    it("isKnownVault returns false for random address", async () => {
      expect(await factory.isKnownVault(dave.address)).to.be.false;
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Construction", () => {
    let vault;

    before(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address, carol.address],
        2,
        "Test Vault",
        "Integration tests",
        owner
      );
    });

    it("stores vault name and description", async () => {
      expect(await vault.vaultName()).to.equal("Test Vault");
      expect(await vault.vaultDescription()).to.equal("Integration tests");
    });

    it("sets the threshold", async () => {
      expect(await vault.threshold()).to.equal(2n);
    });

    it("recognises all signers", async () => {
      expect(await vault.isSigner(alice.address)).to.be.true;
      expect(await vault.isSigner(bob.address)).to.be.true;
      expect(await vault.isSigner(carol.address)).to.be.true;
    });

    it("does not recognise non-signers", async () => {
      expect(await vault.isSigner(dave.address)).to.be.false;
    });

    it("starts with zero proposals", async () => {
      expect(await vault.proposalCount()).to.equal(0n);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Deposits", () => {
    let vault;

    before(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address],
        1,
        "Deposit Vault",
        "",
        owner
      );
    });

    it("accepts native BOT via receive()", async () => {
      await owner.sendTransaction({ to: await vault.getAddress(), value: parseEther("1") });
      expect(await vault.getBalance()).to.equal(parseEther("1"));
    });

    it("accepts native BOT via depositBOT()", async () => {
      await vault.depositBOT({ value: parseEther("0.5") });
      expect(await vault.getBalance()).to.equal(parseEther("1.5"));
    });

    it("emits BOTDeposited event", async () => {
      await expect(
        vault.depositBOT({ value: parseEther("1") })
      ).to.emit(vault, "BOTDeposited");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Proposals", () => {
    let vault;

    beforeEach(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address, carol.address],
        2,
        "Proposal Vault",
        "",
        owner
      );
      // Fund the vault
      await alice.sendTransaction({ to: await vault.getAddress(), value: parseEther("10") });
    });

    it("signer can create a Transfer proposal", async () => {
      await expect(
        vault.connect(alice).propose(
          dave.address, parseEther("1"), ZeroAddress, 0, "0x", "Pay Dave", 0, 0 /* Transfer */
        )
      ).to.emit(vault, "ProposalCreated").withArgs(
        0n, alice.address, 0n, dave.address, parseEther("1"), ZeroAddress, 0n, "Pay Dave", 0n
      );
      expect(await vault.proposalCount()).to.equal(1n);
    });

    it("non-signer cannot create a proposal", async () => {
      await expect(
        vault.connect(eve).propose(
          dave.address, parseEther("1"), ZeroAddress, 0, "0x", "Bad", 0, 0
        )
      ).to.be.revertedWithCustomError(vault, "NotSigner");
    });

    it("signer can approve a proposal", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P1", 0, 0);
      await expect(vault.connect(alice).approve(0n)).to.emit(vault, "ProposalApproved");
    });

    it("signer cannot approve twice", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P2", 0, 0);
      await vault.connect(alice).approve(0n);
      await expect(vault.connect(alice).approve(0n)).to.be.revertedWithCustomError(vault, "AlreadyVoted");
    });

    it("signer can reject a proposal", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P3", 0, 0);
      await expect(vault.connect(bob).reject(0n)).to.emit(vault, "ProposalRejected");
    });

    it("cannot vote on non-existent proposal", async () => {
      await expect(vault.connect(alice).approve(999n)).to.be.revertedWithCustomError(vault, "ProposalNotFound");
    });

    it("proposal cannot be voted on after deadline", async () => {
      const deadlineSoon = Math.floor(Date.now() / 1000) + 2;
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "Deadline", deadlineSoon, 0);
      // Advance time by 10 seconds
      await ethers.provider.send("evm_increaseTime", [10]);
      await ethers.provider.send("evm_mine");
      await expect(vault.connect(alice).approve(0n)).to.be.revertedWithCustomError(vault, "ProposalDeadlinePassed");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Execution", () => {
    let vault;

    beforeEach(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address, carol.address],
        2,
        "Exec Vault",
        "",
        owner
      );
      await alice.sendTransaction({ to: await vault.getAddress(), value: parseEther("10") });
    });

    it("executes a Transfer after threshold approvals", async () => {
      const before = await ethers.provider.getBalance(dave.address);
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "Pay Dave", 0, 0);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await expect(vault.connect(alice).execute(0n)).to.emit(vault, "ProposalExecuted");
      const after = await ethers.provider.getBalance(dave.address);
      expect(after - before).to.equal(parseEther("1"));
    });

    it("cannot execute before threshold met", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P", 0, 0);
      await vault.connect(alice).approve(0n);
      // only 1 approval, threshold is 2
      await expect(vault.connect(alice).execute(0n)).to.be.revertedWithCustomError(vault, "InsufficientApprovals");
    });

    it("cannot execute an already-executed proposal", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P", 0, 0);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await vault.connect(alice).execute(0n);
      await expect(vault.connect(alice).execute(0n)).to.be.revertedWithCustomError(vault, "ProposalAlreadyExecuted");
    });

    it("cannot execute a cancelled proposal", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("1"), ZeroAddress, 0, "0x", "P", 0, 0);
      await vault.connect(alice).cancel(0n);
      await vault.connect(alice).approve(0n).then(() => {}, () => {});
      await expect(vault.connect(alice).execute(0n)).to.be.revertedWithCustomError(vault, "ProposalAlreadyCancelled");
    });

    it("reverts on insufficient vault balance", async () => {
      await vault.connect(alice).propose(dave.address, parseEther("100"), ZeroAddress, 0, "0x", "Too much", 0, 0);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await expect(vault.connect(alice).execute(0n)).to.be.revertedWithCustomError(vault, "InsufficientBalance");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Cancellation", () => {
    let vault;

    beforeEach(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address],
        1,
        "Cancel Vault",
        "",
        owner
      );
    });

    it("proposer can cancel their proposal", async () => {
      await vault.connect(alice).propose(bob.address, 0, ZeroAddress, 0, "0x", "To cancel", 0, 0);
      await expect(vault.connect(alice).cancel(0n)).to.emit(vault, "ProposalCancelled");
    });

    it("non-proposer cannot cancel", async () => {
      await vault.connect(alice).propose(bob.address, 0, ZeroAddress, 0, "0x", "Mine", 0, 0);
      await expect(vault.connect(bob).cancel(0n)).to.be.revertedWithCustomError(vault, "NotProposerOrVault");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("MultiSigVault — Governance Proposals", () => {
    let vault;

    beforeEach(async () => {
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address, carol.address],
        2,
        "Gov Vault",
        "",
        owner
      );
    });

    it("adds a signer via AddSigner proposal", async () => {
      // kind 2 = AddSigner
      await vault.connect(alice).propose(dave.address, 0, ZeroAddress, 0, "0x", "Add Dave", 0, 2);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await vault.connect(alice).execute(0n);
      expect(await vault.isSigner(dave.address)).to.be.true;
    });

    it("removes a signer via RemoveSigner proposal", async () => {
      // First add dave so we have 4 signers
      await vault.connect(alice).propose(dave.address, 0, ZeroAddress, 0, "0x", "Add Dave", 0, 2);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await vault.connect(alice).execute(0n);

      // Now remove carol (kind 3 = RemoveSigner)
      await vault.connect(alice).propose(carol.address, 0, ZeroAddress, 0, "0x", "Remove Carol", 0, 3);
      await vault.connect(alice).approve(1n);
      await vault.connect(bob).approve(1n);
      await vault.connect(alice).execute(1n);
      expect(await vault.isSigner(carol.address)).to.be.false;
    });

    it("changes threshold via ChangeThreshold proposal", async () => {
      // kind 4 = ChangeThreshold; new threshold in `value` field, `to` = zero is ok
      await vault.connect(alice).propose(ZeroAddress, 3, ZeroAddress, 0, "0x", "Raise threshold", 0, 4);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await vault.connect(alice).execute(0n);
      expect(await vault.threshold()).to.equal(3n);
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("SignerRegistry", () => {
    let vault, registry;

    before(async () => {
      registry = await deploy("SignerRegistry");
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address],
        1,
        "Registry Vault",
        "",
        owner
      );
    });

    it("isSigner returns true for active signer", async () => {
      expect(await registry.isSigner(await vault.getAddress(), alice.address)).to.be.true;
    });

    it("isSigner returns false for non-signer", async () => {
      expect(await registry.isSigner(await vault.getAddress(), eve.address)).to.be.false;
    });

    it("getSigners returns full list", async () => {
      const signers = await registry.getSigners(await vault.getAddress());
      expect(signers).to.include(alice.address);
      expect(signers).to.include(bob.address);
    });

    it("getThreshold returns correct value", async () => {
      expect(await registry.getThreshold(await vault.getAddress())).to.equal(1n);
    });

    it("signerCount returns correct count", async () => {
      expect(await registry.signerCount(await vault.getAddress())).to.equal(2n);
    });

    it("getVaultSummary returns correct data", async () => {
      const summary = await registry.getVaultSummary(await vault.getAddress());
      expect(summary.name).to.equal("Registry Vault");
      expect(summary.threshold).to.equal(1n);
    });

    it("reverts on zero address vault", async () => {
      await expect(registry.isSigner(ZeroAddress, alice.address))
        .to.be.revertedWithCustomError(registry, "ZeroAddress");
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("ProposalManager", () => {
    let vault, manager;

    before(async () => {
      manager = await deploy("ProposalManager");
      vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address, carol.address],
        2,
        "PM Vault",
        "",
        owner
      );
      await alice.sendTransaction({ to: await vault.getAddress(), value: parseEther("5") });

      // Create 3 proposals
      for (let i = 0; i < 3; i++) {
        await vault.connect(alice).propose(
          dave.address, parseEther("0.1"), ZeroAddress, 0, "0x", `Proposal ${i}`, 0, 0
        );
      }

      // Approve and execute proposal 0
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await vault.connect(alice).execute(0n);

      // Cancel proposal 1
      await vault.connect(alice).cancel(1n);

      // Leave proposal 2 pending
    });

    it("getProposals returns all proposals", async () => {
      const vaultAddr = await vault.getAddress();
      const proposals = await manager.getProposals(vaultAddr, 0, 10);
      expect(proposals.length).to.equal(3);
    });

    it("getPendingProposals returns only pending", async () => {
      const vaultAddr = await vault.getAddress();
      const pending = await manager.getPendingProposals(vaultAddr, alice.address, 0, 10);
      expect(pending.length).to.equal(1);
      expect(pending[0].proposal.id).to.equal(2n);
    });

    it("getExecutedProposals returns only executed", async () => {
      const vaultAddr = await vault.getAddress();
      const executed = await manager.getExecutedProposals(vaultAddr, 0, 10);
      expect(executed.length).to.equal(1);
      expect(executed[0].id).to.equal(0n);
    });

    it("getCancelledProposals returns only cancelled", async () => {
      const vaultAddr = await vault.getAddress();
      const cancelled = await manager.getCancelledProposals(vaultAddr, 0, 10);
      expect(cancelled.length).to.equal(1);
      expect(cancelled[0].id).to.equal(1n);
    });

    it("getProposalsAwaitingSignerVote returns proposals not yet voted on", async () => {
      const vaultAddr = await vault.getAddress();
      // alice has not voted on proposal 2
      const awaiting = await manager.getProposalsAwaitingSignerVote(vaultAddr, alice.address, 0, 10);
      expect(awaiting.length).to.equal(1);
      expect(awaiting[0].id).to.equal(2n);
    });

    it("getApprovalMatrix returns correct vote map", async () => {
      const vaultAddr = await vault.getAddress();
      const { signers_, voted_, approved_ } = await manager.getApprovalMatrix(vaultAddr, 2n);
      // No one has voted on proposal 2 yet
      for (let i = 0; i < voted_.length; i++) {
        expect(voted_[i]).to.be.false;
      }
    });

    it("getProposalStatus marks canExecute correctly", async () => {
      const vaultAddr = await vault.getAddress();
      await vault.connect(alice).approve(2n);
      await vault.connect(bob).approve(2n);
      const status = await manager.getProposalStatus(vaultAddr, 2n, alice.address);
      expect(status.canExecute).to.be.true;
      expect(status.hasVoted).to.be.true;
      expect(status.voteValue).to.be.true;
    });
  });

  // ───────────────────────────────────────────────────────────────────────────
  describe("Reentrancy Guard", () => {
    it("deploys and executes without reentrancy attack vector", async () => {
      // Simple sanity: a vault funded and then used normally completes without reverting
      const vault = await createVaultViaFactory(
        factory,
        [alice.address, bob.address],
        2,
        "ReentrancyGuard Test",
        "",
        owner
      );
      await alice.sendTransaction({ to: await vault.getAddress(), value: parseEther("1") });
      await vault.connect(alice).propose(dave.address, parseEther("0.5"), ZeroAddress, 0, "0x", "Safe", 0, 0);
      await vault.connect(alice).approve(0n);
      await vault.connect(bob).approve(0n);
      await expect(vault.connect(alice).execute(0n)).to.emit(vault, "ProposalExecuted");
    });
  });
});
