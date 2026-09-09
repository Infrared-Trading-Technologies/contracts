# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrared Contracts -- Solidity contracts for the Infrared execution layer. `Router` is the user-facing contract: it holds approvals and native ETH, applies fees and slippage, and delegates Weiroll execution to `ExecutionProxy`. Includes helper contracts (`Tupler`, `Integer`, `Bytes32`, `BlockchainInfo`, `ArraysConverter`, `MathHelpers`, `SignedMathHelpers`, `UniswapV4SwapHelpers`) that provide Weiroll-compatible utilities.

License: BUSL-1.1

## Build Commands

```bash
forge build                        # Compile
forge test                         # Run all tests
forge test -vvv                    # Verbose test output
forge test --match-test testName   # Run single test
forge test --match-contract Name   # Run tests in one contract
forge fmt                          # Format code
forge fmt --check                  # Check formatting (CI uses this)
forge soldeer install              # Install dependencies
```

## Deployment

Uses CREATE3 for deterministic cross-chain addresses. Factory: `0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf`.

```bash
./deploy.sh preview <chain-id>    # Preview addresses
./deploy.sh dry-run <chain-id>    # Simulate deployment
./deploy.sh deploy <chain-id>     # Deploy + generate registry
./deploy.sh verify <chain-id>     # Verify on explorer
./deploy.sh list-chains           # Show supported chains
```

Signs with a Foundry-encrypted keystore (`~/.foundry/keystores/<name>`). Create one via `./setup-deployer-wallet.sh <name>`. Config via `.env` (see `.env.example`). Key env vars: `KEYSTORE_ACCOUNT`, `DEPLOYER_ADDRESS`, `SAFE_ADDRESS`, `ROUTER_LIQUIDATOR`, `<CHAIN>_RPC_URL`.

Supported chains: Ethereum (1), Base (8453), Arbitrum One (42161), Sepolia (11155111), Base Sepolia (84532).

After deploying a new chain, the Router owner multisig must wire the executor (`setPendingExecutor` + `acceptExecutor`). `./deploy.sh wire-propose <chain-id>` proposes that batch straight to the Safe Transaction Service; `./deploy.sh wire-bundle <chain-id>` writes a Safe Tx Builder JSON to import by hand instead. The chain is not live until `router.executor()` returns the ExecutionProxy address.

Both repos must agree on deployed addresses: after a deploy, populate the chain in `infrared/internal/protocol/infrared/addresses.go` (`chainAddressMap`), or `IsChainSupported` treats it as unsupported.

## Architecture

- **Solidity 0.8.24**, optimizer at 200 runs
- **Dependencies** managed via Soldeer (stored in `dependencies/`)
- **Import remappings**: `forge-std/`, `@openzeppelin/contracts/`, `solmate/`. Weiroll VM + CommandBuilder live in-tree under `src/weiroll/` rather than as an external dependency.

### Core Contract

`src/ExecutionProxy.sol` is `VM, IExecutor` -- a deliberately minimal Weiroll executor bound to one Router. The constructor takes the Router address (immutable `ROUTER`); `executePath` reverts `NotRouter` for any other caller, because the Router stages user funds on the executor and an open entry point would let anyone run a program against them. No owner, no reentrancy guard of its own, no other storage, no admin functions (FR-11). Single entry point:
- `executePath(bytes32[] commands, bytes[] state)` -- payable, Router-only

Rotating the Router means deploying a new executor bound to it.

The Router owns pulls, fees, slippage verification, and recipient transfers, and enforces the `nonReentrant` boundary. `receive()` and `fallback()` stay payable so the Router can forward native ETH and Weiroll sub-calls (e.g. WETH unwraps) can return it. Native ETH is represented by sentinel address `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`.

### Weiroll Helpers

`src/weiroll-helpers/` -- stateless utility contracts designed for use as Weiroll command targets (comparison ops, type conversion, block data access, array manipulation, tuple extraction).

### Test Structure

- `test/ExecutionProxy.t.sol` -- main test suite
- `test/WeirollTestHelper.t.sol` -- helper utility tests
- `test/helpers/WeirollTestHelper.sol` -- library for encoding Weiroll commands and building state arrays in tests
- `test/mocks/` -- MockDEX, adversarial tokens (fee-on-transfer, rebasing, callback, false-returning), reentrancy attacker

## CI Pipeline

GitHub Actions runs: `forge build`, `forge test -vvv`, `forge fmt --check`, Slither static analysis, and deployment dry-runs.
