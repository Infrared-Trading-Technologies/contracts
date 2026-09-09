# Infrared Contracts

Solidity contracts for the Infrared execution layer. The `Router` is the user-facing entry point; it holds ERC20 approvals, fees, and slippage state and delegates Weiroll execution to the stateless `ExecutionProxy`.

## Contracts

| Contract          | Description                                                                  |
| ----------------- | ---------------------------------------------------------------------------- |
| `Router`          | User-facing entry point: ERC20 approvals, fees, slippage; `Ownable2Step`     |
| `ExecutionProxy`  | Weiroll VM executor; `executePath` callable only by its bound Router         |
| `Tupler`          | Byte tuple extraction helper                                                 |
| `Integer`         | Comparison utilities                                                         |
| `Bytes32`         | Type conversion                                                              |
| `BlockchainInfo`  | Block data reader                                                            |
| `ArraysConverter` | Array manipulation                                                           |

## Getting Started

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation). Run the init script to install dependencies, build, and test:

```bash
./init.sh
```

Or manually:

```bash
forge soldeer install
forge build
forge test
```

## Build

```bash
forge build
forge test
forge fmt --check
```

## Deployment

Uses CREATE3 for deterministic addresses across chains.

```bash
./deploy.sh preview <chain-id>     # Preview addresses
./deploy.sh dry-run <chain-id>     # Simulate deployment
./deploy.sh deploy <chain-id>      # Deploy + generate registry
./deploy.sh verify <chain-id>      # Verify on block explorer
./deploy.sh list-chains            # Show supported chains
```

Signing uses a Foundry-encrypted keystore. Create one once:

```bash
./setup-deployer-wallet.sh infrared-deployer
```

This generates a fresh keypair encrypted at `~/.foundry/keystores/infrared-deployer`; Foundry prompts for the password at broadcast time. Then copy `.env.example` to `.env` and configure:

- `KEYSTORE_ACCOUNT` -- account name passed to `setup-deployer-wallet.sh`
- `DEPLOYER_ADDRESS` -- address printed by the setup script
- `SAFE_ADDRESS` -- Gnosis Safe multisig, required for mainnet
- `ROUTER_LIQUIDATOR` -- liquidator hot wallet (run setup script again with a different account name)
- `<CHAIN>_RPC_URL` -- RPC endpoint for target chain

## License

[BUSL-1.1](LICENSE)
