# Robinhood Chain (4663) deployment

Status 2026-10-20: prerequisites verified on-chain, nothing deployed yet. Two facts shape this chain:

- **Same-address Router/ExecutionProxy is impossible here.** ZeframLou's CREATE3Factory (0x9fBB…0ABf) was an EOA nonce-0 deploy on every chain (Ethereum creation tx `0xb05de371a18fc4f02753b34a689939cee69b93a043b926732043780959b7c4e3`, deployer `0x9d1ed270…494e`), so only that key can reproduce it. We deploy our own instance of the same bytecode through the Arachnid CREATE2 deployer with salt 0; it lands at **0x6aA3D87e99286946161dCA02B97C5806fC5eD46F**. Router and ExecutionProxy addresses on 4663 therefore differ from other chains, and `infrared/internal/protocol/infrared/addresses.go` must carry a per-chain entry.
- **The owner Safe can be recreated at its exact address.** `0xb0217656A8160fa6D601c95844a73173237DEcFE` was created with Safe 1.4.1 (factory `0x4e1DCf7A…ec67`, singleton `0x41675C09…461a`, salt nonce 0). The factory, singleton, SafeL2, SafeToL2Setup and the fallback handler are all live on 4663 (checked 2026-10-20), and the computed CREATE2 address matches. The Safe web app does not list this chain, so day-to-day owner actions need `wire-bundle` + a manual execution path or an EOA owner.

Verified on 4663 (2026-10-20): Permit2, Multicall3, CreateX, Arachnid CREATE2 deployer present; PUSH0, TSTORE, MCOPY execute (Cancun); Uniswap v4 PoolManager `0x8366a39cc670b4001a1121b8f6a443a643e40951`, Universal Router 2.1.2 `0x204FAca1764B154221e35c0d20aBb3c525710498`. Public RPC `https://rpc.mainnet.chain.robinhood.com` (rate-limited; use Alchemy for deploys). Explorer: Blockscout, no API key.

## 0. Environment

```
ROBINHOOD_RPC_URL=<alchemy or other keyed rpc>
KEYSTORE_ACCOUNT=infrared-deployer
DEPLOYER_ADDRESS=0xD1c4f07c277Bcc155693E3a569A9587E9237bA07
ROUTER_SIGNER_4663=<gateway signer address>     # go run ./cmd/signer-address in infrared/
SAFE_ADDRESS=0xb0217656A8160fa6D601c95844a73173237DEcFE   # omit for an EOA-owned Router (see step 4)
```

Fund the deployer with ETH on 4663 first. Canonical bridge from Ethereum/Arbitrum confirms in ~10 min; Relay and Across are faster. Gas is ~0.02 gwei; 0.01 ETH covers everything below.

## 1. Recreate the owner Safe (optional, see step 4)

Setup data is the exact initializer from the Base creation (`api.safe.global/tx-service/base/api/v1/safes/0xb021…/creation/`). Any funded account can send this.

```
SETUP=$(curl -sL -H accept:application/json \
  https://api.safe.global/tx-service/base/api/v1/safes/0xb0217656A8160fa6D601c95844a73173237DEcFE/creation/ | jq -r .setupData)
cast send 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67 \
  "createProxyWithNonce(address,bytes,uint256)" \
  0x41675C099F32341bf84BFc5382aF534df5C7461a "$SETUP" 0 \
  --rpc-url "$ROBINHOOD_RPC_URL" --account "$KEYSTORE_ACCOUNT"
cast code 0xb0217656A8160fa6D601c95844a73173237DEcFE --rpc-url "$ROBINHOOD_RPC_URL" | wc -c   # > 3
```

## 2. Deploy our CREATE3Factory instance

Replay the original factory init code through the Arachnid deployer (`0x4e59b448…956C`) with a zero salt. The init code is the input of the Ethereum creation tx, so nothing is hand-copied.

```
INIT=$(cast tx 0xb05de371a18fc4f02753b34a689939cee69b93a043b926732043780959b7c4e3 --rpc-url https://ethereum.publicnode.com --json | jq -r .input)
cast send 0x4e59b44847b379578588920cA78FbF26c0B4956C \
  "0x0000000000000000000000000000000000000000000000000000000000000000${INIT#0x}" \
  --rpc-url "$ROBINHOOD_RPC_URL" --account "$KEYSTORE_ACCOUNT"
cast code 0x6aA3D87e99286946161dCA02B97C5806fC5eD46F --rpc-url "$ROBINHOOD_RPC_URL" | wc -c   # 3193 bytes, same as Base
```

`chains.json` already points 4663 at this factory; `deploy.sh` exports it to the Foundry script, which prints a warning that addresses will differ.

## 3. Deploy and verify

```
./deploy.sh preview 4663
./deploy.sh deploy 4663
./deploy.sh verify 4663        # Blockscout, no API key
git add deployments/4663.json && git commit -m "chore(deploy): Robinhood Chain"
```

`check_v4_layout` skips 4663 (no Universal Router pinned), so `UniswapV4SwapHelpers` is not deployed. To route Uniswap v4 on this chain later: pin Universal Router 2.1.2 (`0x204FAca1…0498`) in `getUniversalRouter()` and `verify()`, add a `test_Layout_Robinhood` fork test, redeploy the helper.

## 4. Owner and executor wiring

The chain is not live until `router.executor()` returns the ExecutionProxy. The owner must call `setPendingExecutor` then `acceptExecutor`.

- **EOA owner (recommended for the demo window):** leave `SAFE_ADDRESS` unset so the deployer owns the Router, run `./deploy.sh wire-bundle 4663` to see the two calls, send them with `cast send … --account "$KEYSTORE_ACCOUNT"`. Transfer ownership to the Safe once an execution path for it exists on this chain.
- **Safe owner:** recreate the Safe (step 1), deploy with `SAFE_ADDRESS` set, then execute the wiring batch outside the Safe web app (safe-cli or signed `execTransaction` via cast with 2 of 3 owner signatures). `wire-propose` will not work: the Safe Transaction Service has no 4663 instance.

## 5. Infrared side

1. `pkg/chain/evm/chain.go`: add `ChainRobinhood ChainID = 4663`, name, env key (`ROBINHOOD_RPC_URLS`).
2. `internal/protocol/infrared/addresses.go`: per-chain Router/ExecutionProxy/helper entries for 4663 from `deployments/4663.json` (the shared `chainAddressMap` values do not apply).
3. Gateway config: `ROUTER_AUTH_SIGNER_KEY_4663` if a distinct signer is used; RPC URLs; enable the chain in the chain list.
4. Venues: Uniswap v4 (PoolManager above) and v3 need chain entries in the protocol registries and a token/pool ingest run before quotes return routes.
5. Golden scenario on a 4663 fork once a stock-token pool is enabled.
