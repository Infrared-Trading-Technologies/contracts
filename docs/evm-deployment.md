# EVM Contract Deployment Guide

Deploy Infrared's Solidity contracts with deterministic addresses using CREATE3.

## Prerequisites

### Required Software
- [Foundry](https://book.getfoundry.sh/getting-started/installation) (`forge`, `cast`)
- `jq` for JSON processing

### Wallet Setup

Deploys sign with a Foundry-encrypted keystore. Generate a fresh hot wallet once:

```bash
./setup-deployer-wallet.sh infrared-deployer
```

This creates an encrypted keystore at `~/.foundry/keystores/infrared-deployer` and prints the deployer address. The plaintext key never touches disk; Foundry prompts for the password at broadcast time. Run the script again with a different account name (e.g. `infrared-liquidator`) to create the Router liquidator wallet.

### Environment Variables

Copy `.env.example` to `.env` in the repo root (auto-loaded by the deploy script) and fill in:

```bash
KEYSTORE_ACCOUNT=infrared-deployer                     # Matches setup-deployer-wallet.sh argument
DEPLOYER_ADDRESS=0x...                                 # Printed by setup-deployer-wallet.sh

SAFE_ADDRESS=0x...                                     # Safe multi-sig (required for mainnet)
ROUTER_OWNER=0x...                                     # Router owner; defaults to SAFE_ADDRESS, else DEPLOYER_ADDRESS
ROUTER_LIQUIDATOR=0x...                                # Liquidator hot wallet (separate keystore)
ROUTER_SIGNER=0x...                                    # Backend authorization signer (required, no fallback)
ROUTER_SIGNER_11155111=0x...                           # Optional per-chain override (testnets use a separate key)

SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
BASE_SEPOLIA_RPC_URL=https://base-sepolia.g.alchemy.com/v2/YOUR_KEY
ETH_RPC_URL=https://eth-mainnet.g.alchemy.com/v2/YOUR_KEY
BASE_RPC_URL=https://base-mainnet.g.alchemy.com/v2/YOUR_KEY
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY   # V2 key; works across all supported chains
```

**Notes:**
- Only the `deploy` command needs the keystore password; `preview` and `dry-run` simulate using `--sender` only.
- `SAFE_ADDRESS` is required for mainnet. For testnet it's optional -- the deployer EOA is used as owner if not provided.
- `ROUTER_SIGNER` (or `ROUTER_SIGNER_<chainId>`) is required on every chain. It is the address of the key the gateway signs swap authorizations with (`go run ./cmd/signer-address` in the backend prints it from the Secret Manager key). A mismatch makes the gateway refuse to build.
- Redeploying the Router (any bytecode change) needs a `SALT_VERSION` bump; one bump covers every Router change since the last deploy.

See `.env.example` for the full template.

### Contracts Deployed

Deploys 7 contracts (order in `chains.json` `contracts`):

| Contract        | Purpose                                                                    |
| --------------- | -------------------------------------------------------------------------- |
| Router          | User-facing entry point: holds ERC20 approvals, fees, slippage; verifies a backend-signed authorization on every swap; `Ownable2Step` |
| ExecutionProxy  | Stateless Weiroll VM executor invoked by the Router (no owner, no storage) |
| Tupler          | Byte tuple extraction helper                                               |
| Integer         | Comparison utilities                                                       |
| Bytes32         | Type conversion helper                                                     |
| BlockchainInfo  | Block data reader                                                          |
| ArraysConverter | Array manipulation                                                         |

## CREATE3 Deterministic Deployment

### How It Works

CREATE3 produces addresses determined only by:
1. Factory address (`0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`)
2. Deployer address
3. Salt

This means identical addresses across any EVM chain when using the same deployer and salt.

### Salt Strategy

Salts are generated deterministically:
```solidity
keccak256(abi.encodePacked("infrared.contracts.v1", contractName))
```

Configure salt version via environment variable for future contract versions:
```bash
SALT_VERSION=v2 ./deploy.sh deploy 1  # Deploy to different addresses
```

### Address Prediction

Preview addresses before deploying:
```bash
cd contracts  # github.com/branched-services/contracts
./deploy.sh preview 11155111  # Sepolia
./deploy.sh preview 84532     # Base Sepolia
```

### Dry-Run (Simulation)

Test deployment without broadcasting transactions:
```bash
./deploy.sh dry-run 11155111  # Compile + simulate, no broadcast
```

## Testnet Deployment

### Step 1: Deploy to Sepolia

```bash
cd contracts  # github.com/branched-services/contracts

# Preview addresses first
./deploy.sh preview 11155111

# Dry-run to verify (optional)
./deploy.sh dry-run 11155111

# Deploy (auto-generates deployments/11155111.json)
./deploy.sh deploy 11155111
```

### Step 2: Verify Contracts

```bash
./deploy.sh verify 11155111
```

### Step 3: Deploy to Base Sepolia

Repeat for Base Sepolia:
```bash
./deploy.sh preview 84532
./deploy.sh deploy 84532  # Auto-generates deployments/84532.json
./deploy.sh verify 84532
```

## Mainnet Deployment

### Pre-Deployment Checklist

- [ ] Testnet deployment successful on both Sepolia and Base Sepolia
- [ ] All contracts verified on testnet explorers
- [ ] Integration tests pass against testnet contracts
- [ ] Safe multi-sig created and `SAFE_ADDRESS` set in `.env`
- [ ] Sufficient ETH/gas in deployer wallet

### Step 1: Create Safe Multi-sig

1. Go to [Safe](https://app.safe.global)
2. Create new Safe with 2-of-3 threshold
3. Add 3 signer addresses
4. Deploy Safe to target chain
5. Add `SAFE_ADDRESS=0x...` to `.env`

### Step 2: Deploy Contracts

The deploy script automatically:
- Validates the Safe exists on-chain before broadcasting
- Deploys the Router with the Safe as constructor owner (`Ownable2Step`)
- Deploys the stateless ExecutionProxy (no owner)
- Records the Safe as `owner` in the deployment registry
- Skips any contract already deployed at its predicted CREATE3 address (idempotent; ownership of an already-deployed Router is **not** rewritten on re-runs)

```bash
# Ethereum Mainnet (requires SAFE_ADDRESS)
./deploy.sh deploy 1

# Base (requires SAFE_ADDRESS)
./deploy.sh deploy 8453
```

### Step 3: Verify Contracts

```bash
./deploy.sh verify 1
./deploy.sh verify 8453
```

### Step 4: Verify Ownership

Confirm the Router is owned by the Safe (the ExecutionProxy is stateless and has no `owner()`):
```bash
cast call <ROUTER_ADDRESS> "owner()(address)" --rpc-url $ETH_RPC_URL
# Should return your SAFE_ADDRESS
```

### Step 5: Wire Router → ExecutionProxy

After deploy, `Router.executor() == address(0)` and every swap entry point reverts. See [Post-Deploy: Wire Router → ExecutionProxy](#post-deploy-wire-router--executionproxy).

## Post-Deploy: Wire Router → ExecutionProxy

The Router enforces a two-step `setPendingExecutor` → `acceptExecutor` transition (Router.sol). Until both run, `Router.executor() == address(0)` and every swap entry point reverts. The flow depends on whether the deployer EOA is also the Router owner.

### Case A: Deployer is the Router owner (testnet without `SAFE_ADDRESS`)

The deploy script broadcasts `setPendingExecutor(executionProxy)` automatically (DeployCreate3.s.sol). Only `acceptExecutor()` is left:

```bash
cast send <ROUTER_ADDRESS> "acceptExecutor()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --account "$KEYSTORE_ACCOUNT" \
  --from "$DEPLOYER_ADDRESS"
```

### Case B: Router owner is a Safe multisig (testnet with `SAFE_ADDRESS`, or mainnet)

The deploy script does **not** call `setPendingExecutor` (the broadcasting EOA is not the owner). The Safe must send both txs.

Compute calldata:

```bash
cast calldata "setPendingExecutor(address)" <EXECUTION_PROXY_ADDRESS>
# 0x554a3f1b<32-byte padded address>

cast calldata "acceptExecutor()"
# 0x1f211405
```

Easiest path: **Safe Transaction Builder** with a JSON batch. Save as `wire-executor-<chain>.json`, then in the Safe app: **Apps → Transaction Builder → Load batch**, drag the file, sign, execute.

```json
{
  "version": "1.0",
  "chainId": "<CHAIN_ID>",
  "meta": {
    "name": "Wire Router executor",
    "createdFromSafeAddress": "<SAFE_ADDRESS>"
  },
  "transactions": [
    {
      "to": "<ROUTER_ADDRESS>",
      "value": "0",
      "data": "<setPendingExecutor calldata>",
      "contractMethod": null,
      "contractInputsValues": null
    },
    {
      "to": "<ROUTER_ADDRESS>",
      "value": "0",
      "data": "0x1f211405",
      "contractMethod": null,
      "contractInputsValues": null
    }
  ]
}
```

Both txs target the Router; batching makes the transition atomic from the signers' perspective.

### Verification

```bash
cast call <ROUTER_ADDRESS> "executor()(address)" --rpc-url $RPC_URL
# Must equal <EXECUTION_PROXY_ADDRESS>; until then the Router reverts on every swap.
```

## Backend Signer

Every user-facing swap carries an EIP-712 authorization signed by the gateway's key (Nethermind NM-1048). The Router accepts `signer()`, or `previousSigner()` until `previousSignerValidUntil()`.

```bash
cast call <ROUTER_ADDRESS> "signer()(address)" --rpc-url $RPC_URL   # must equal the gateway's key address
```

**Routine rotation** (do the on-chain step first; the reverse order fails closed, never open):
1. Generate the new key, store it in Secret Manager, print its address: `go run ./cmd/signer-address`.
2. Owner: `setSigner(<new>, 900)` on every chain that uses the key (15 min grace keeps in-flight authorizations valid).
3. Roll the gateway to the new key inside the grace window; the boot-time signer probe must pass on every chain.

**Compromise**: `revokeSigner()` from the liquidator hot wallet (immediate, fail closed, no multisig latency) or `setSigner(<new>, 0)` from the owner, on every chain that shares the key. Any non-zero grace keeps the old key alive for that long; treat it as a security decision. `setSigner(0, <grace>)` drains in-flight authorizations without issuing new ones.

**Retiring a previous Router** after a redeploy: the old contract keeps accepting its old calldata until paused.

```bash
./deploy.sh retire-propose <chain-id> <old-router>   # proposes pause() to the Safe
# execute in the Safe, sweep with transferRouterFunds, then:
RETIRE_TOKENS=0x...,0x... ./deploy.sh retire-verify <chain-id>   # exits non-zero until paused and empty
```

`RETIRE_TOKENS` is required: list every token the old Router held protocol fees or captured slippage in (the `Swap` / `MultiSwap` logs give the set). Without it the command refuses to run rather than pass on native ETH alone.

## Post-Deployment Verification

### Automated Checks

```bash
cd contracts  # github.com/branched-services/contracts
forge script script/Verify.s.sol:VerifyDeployment \
  --rpc-url $ETH_RPC_URL \
  --sig "run(uint256)" 1
```

### Manual Checklist

- [ ] All 7 contracts have code at expected addresses (Router, ExecutionProxy, Tupler, Integer, Bytes32, BlockchainInfo, ArraysConverter)
- [ ] Router `owner()` is the Safe address (mainnet) or deployer (testnet without `SAFE_ADDRESS`)
- [ ] Router `executor()` equals the deployed ExecutionProxy address (see [post-deploy wiring](#post-deploy-wire-router--executionproxy))
- [ ] Contracts verified on block explorers
- [ ] `Router.pause()` / `unpause()` callable by owner only
- [ ] Test execution via API succeeds

### Safe Configuration Verification

1. Verify Safe at [app.safe.global](https://app.safe.global)
2. Confirm 3 signers present
3. Confirm 2-of-3 threshold
4. Test with low-value transaction

## Adding New Chains

1. Add chain config to `chains.json`:
```json
{
  "chains": {
    "<CHAIN_ID>": {
      "name": "<chain-name>",
      "displayName": "<Chain Name>",
      "create3Factory": "0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf",
      "explorer": {
        "url": "https://...",
        "apiUrl": "https://api.etherscan.io/v2/api?chainid=<CHAIN_ID>",
        "apiKeyEnv": "ETHERSCAN_API_KEY"
      },
      "rpcEnv": "<CHAIN>_RPC_URL",
      "isTestnet": false
    }
  }
}
```

2. Add new contracts to the `contracts` array if needed:
```json
{
  "contracts": ["ExecutionProxy", "Router", "Tupler", "Integer", "Bytes32", "BlockchainInfo", "ArraysConverter"]
}
```

3. Set environment variables and deploy.

## Idempotency

The deployment script is idempotent:
- Checks if contract exists at predicted address before deploying
- Skips already-deployed contracts
- Safe to re-run after partial failures

```
$ ./deploy.sh deploy 1
ExecutionProxy already deployed at: 0x...
Tupler already deployed at: 0x...
Integer deployed at: 0x...  # Only deploys missing contracts
```

## Upgradeability Patterns

### Current Design: Immutable

All contracts are deployed as immutable (non-upgradeable):
- Simpler security model
- No proxy overhead
- Deterministic addresses forever

### Future Options

If upgradeability is needed:

**UUPS (Universal Upgradeable Proxy Standard)**
- Upgrade logic in implementation contract
- Smaller proxy bytecode
- [OpenZeppelin UUPS](https://docs.openzeppelin.com/contracts/5.x/api/proxy#UUPSUpgradeable)

**Transparent Proxy**
- Upgrade logic in proxy
- Admin cannot call implementation functions
- [OpenZeppelin TransparentProxy](https://docs.openzeppelin.com/contracts/5.x/api/proxy#TransparentUpgradeableProxy)

**Migration Strategy**
1. Deploy new version via CREATE3 with new salt (e.g., `v2`)
2. Update API to use new addresses
3. Keep old contracts for existing integrations

## Troubleshooting

### Verification Fails
- Ensure `ETHERSCAN_API_KEY` is a valid Etherscan V2 key. Legacy per-explorer keys (BscScan, BaseScan, PolygonScan) return `Invalid API key`
- Etherscan V2 has rate limits; wait and retry
- Verify constructor args match exactly

### CREATE3 Factory Not Deployed {#factory-deployment}
The factory is deployed on most EVM chains at `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`. If missing:
1. Check [create3-factory repo](https://github.com/ZeframLou/create3-factory) for deployment instructions
2. Deploy factory first, then contracts
3. The deploy script will fail with a clear error if factory is missing

## Partial Failure Recovery

The deployment script is idempotent - safe to re-run after failures.

### How It Works
- Checks if contract exists at predicted address before deploying
- Skips already-deployed contracts
- Only deploys missing contracts

### Recovery Steps

1. **Identify what deployed**: Check forge output or run `./deploy.sh preview <chain-id>`
2. **Re-run deployment**: `./deploy.sh deploy <chain-id>` - only missing contracts will deploy
3. **Verify registry**: The auto-generated `deployments/<chain-id>.json` will include all contracts

### Example
```
$ ./deploy.sh deploy 1
ExecutionProxy already deployed at: 0x...
Tupler already deployed at: 0x...
Integer deployed at: 0x...  # Only deploys missing contracts
```
