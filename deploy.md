# SafeVault — Deployment Guide

## Prerequisites

- Node.js >= 18
- npm >= 9
- MetaMask with BOT Chain configured
- A funded deployer wallet (for gas)

---

## 1. Project Setup

```bash
mkdir safevault-deploy && cd safevault-deploy
npm init -y
npm install --save-dev hardhat @nomicfoundation/hardhat-toolbox
npm install @openzeppelin/contracts dotenv
npx hardhat init   # choose "Create an empty Hardhat project"
```

Copy all `.sol` files from `contracts/` into `contracts/`.

---

## 2. Environment Variables

Create `.env`:

```env
PRIVATE_KEY=0xyour_deployer_private_key
BOT_RPC_URL=https://rpc.botchain.tg
EXPLORER_API_KEY=your_explorer_api_key_if_available
```

---

## 3. Hardhat Configuration

Replace `hardhat.config.js`:

```js
require("@nomicfoundation/hardhat-toolbox");
require("dotenv").config();

module.exports = {
  solidity: {
    version: "0.8.20",
    settings: { optimizer: { enabled: true, runs: 200 } }
  },
  networks: {
    botchain: {
      url: process.env.BOT_RPC_URL || "https://rpc.botchain.tg",
      chainId: 677,
      accounts: [process.env.PRIVATE_KEY],
      gasPrice: "auto"
    }
  },
  etherscan: {
    apiKey: { botchain: process.env.EXPLORER_API_KEY || "none" },
    customChains: [{
      network: "botchain",
      chainId: 677,
      urls: {
        apiURL: "https://explorer.botchain.tg/api",
        browserURL: "https://explorer.botchain.tg"
      }
    }]
  }
};
```

---

## 4. Compile

```bash
npx hardhat compile
```

Expected output: `Compiled 4 Solidity files successfully`.

---

## 5. Deploy Script

Create `scripts/deploy.js`:

```js
const { ethers } = require("hardhat");
const fs = require("fs");

async function main() {
  const [deployer] = await ethers.getSigners();
  console.log("Deploying with:", deployer.address);
  console.log("Balance:", ethers.formatEther(await ethers.provider.getBalance(deployer.address)), "BOT");

  // 1. Deploy SignerRegistry
  const SignerRegistry = await ethers.getContractFactory("SignerRegistry");
  const signerRegistry = await SignerRegistry.deploy();
  await signerRegistry.waitForDeployment();
  console.log("SignerRegistry:", await signerRegistry.getAddress());

  // 2. Deploy ProposalManager
  const ProposalManager = await ethers.getContractFactory("ProposalManager");
  const proposalManager = await ProposalManager.deploy();
  await proposalManager.waitForDeployment();
  console.log("ProposalManager:", await proposalManager.getAddress());

  // 3. Deploy VaultFactory (depends on SignerRegistry + ProposalManager)
  const VaultFactory = await ethers.getContractFactory("VaultFactory");
  const vaultFactory = await VaultFactory.deploy(
    await signerRegistry.getAddress(),
    await proposalManager.getAddress()
  );
  await vaultFactory.waitForDeployment();
  console.log("VaultFactory:", await vaultFactory.getAddress());

  // Save addresses
  const addresses = {
    network: "botchain",
    chainId: 677,
    deployedAt: new Date().toISOString(),
    deployer: deployer.address,
    contracts: {
      SignerRegistry: await signerRegistry.getAddress(),
      ProposalManager: await proposalManager.getAddress(),
      VaultFactory: await vaultFactory.getAddress()
    }
  };

  fs.writeFileSync("deployed-addresses.json", JSON.stringify(addresses, null, 2));
  console.log("\nDeployment complete. Addresses saved to deployed-addresses.json");
}

main().catch((e) => { console.error(e); process.exit(1); });
```

Run:

```bash
npx hardhat run scripts/deploy.js --network botchain
```

---

## 6. Verify Contracts

```bash
# SignerRegistry (no constructor args)
npx hardhat verify --network botchain <SIGNER_REGISTRY_ADDRESS>

# ProposalManager (no constructor args)
npx hardhat verify --network botchain <PROPOSAL_MANAGER_ADDRESS>

# VaultFactory
npx hardhat verify --network botchain <VAULT_FACTORY_ADDRESS> \
  "<SIGNER_REGISTRY_ADDRESS>" "<PROPOSAL_MANAGER_ADDRESS>"
```

---

## 7. Update Frontend Config

Open `index.html` and find the `CONFIG` block near the top of the `<script>` section:

```js
const CONFIG = {
  chainId: 677,
  rpcUrl: "https://rpc.botchain.tg",
  explorerUrl: "https://explorer.botchain.tg",
  contracts: {
    VaultFactory: "PASTE_VAULT_FACTORY_ADDRESS_HERE",
    SignerRegistry: "PASTE_SIGNER_REGISTRY_ADDRESS_HERE",
    ProposalManager: "PASTE_PROPOSAL_MANAGER_ADDRESS_HERE"
  }
};
```

Replace the placeholder strings with the addresses from `deployed-addresses.json`.

---

## 8. Post-Deployment Checklist

### Contract Verification
- [ ] All 3 contracts verified on BOT Chain explorer
- [ ] VaultFactory owner is the intended deployer address
- [ ] VaultFactory references correct SignerRegistry and ProposalManager addresses

### Functional Smoke Tests
- [ ] Connect MetaMask to chainId 677
- [ ] Create a test vault (2-of-3 signers using 3 test wallets)
- [ ] Deposit BOT into the vault
- [ ] Create a transfer proposal from signer 1
- [ ] Approve from signer 2 — proposal should auto-execute at threshold
- [ ] Verify BOT received by recipient
- [ ] Test rejection flow: reject from 2 signers, confirm proposal is dead
- [ ] Test cancellation by proposer

### ERC-20 Token Tests
- [ ] Deploy a test ERC-20 token or use an existing one on BOT Chain
- [ ] Deposit token into vault
- [ ] Create and execute a token transfer proposal
- [ ] Verify SafeERC20 transfer succeeded

### Security Checks
- [ ] Confirm no signer can approve a proposal twice (transaction reverts)
- [ ] Confirm non-signer cannot approve (reverts with AccessDenied)
- [ ] Confirm proposal cannot execute before threshold is met
- [ ] Confirm executed proposal cannot be executed again

### Operations
- [ ] Store deployer private key securely — not in version control
- [ ] Delete `.env` or move to secure secrets manager
- [ ] Consider transferring VaultFactory ownership to a multisig

---

## 9. Troubleshooting

| Error | Likely Cause | Fix |
|-------|-------------|-----|
| `nonce too low` | Prior failed tx | Reset MetaMask account nonce |
| `insufficient funds` | Low deployer balance | Top up deployer wallet |
| `execution reverted` | Constructor arg mismatch | Check addresses passed to VaultFactory |
| `already verified` | Contract previously verified | No action needed |
| TLS errors | Proxy config | Check `/root/.ccr/README.md` |
