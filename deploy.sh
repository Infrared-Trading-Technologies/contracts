#!/bin/bash
set -euo pipefail

# Infrared Contract Deployment Script
# Uses CREATE3 for deterministic addresses across chains.
#
# Contracts deployed (order defined in chains.json "contracts"):
#   Router          -- primary user-facing contract; holds ERC20 approvals + fee/slippage model
#   ExecutionProxy  -- pure Weiroll VM executor (stateless, no constructor)
#   Tupler, Integer, Bytes32, BlockchainInfo, ArraysConverter -- stateless Weiroll helpers
#
# Router.executor is wired via a two-step registry:
#   1. DeployCreate3 calls router.setPendingExecutor(executionProxy) in-script ONLY when the
#      broadcasting EOA is also ROUTER_OWNER. Production deploys from a multisig MUST send
#      both setPendingExecutor() and acceptExecutor() as follow-up multisig txs.
#   2. The Router owner multisig MUST send `router.acceptExecutor()` before the Router can
#      serve any swaps. The `deploy` command prints a reminder after each broadcast.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAINS_FILE="$SCRIPT_DIR/chains.json"
DEPLOYMENTS_DIR="$SCRIPT_DIR/deployments"

# Auto-source .env from repo root if it exists
if [[ -f "$SCRIPT_DIR/.env" ]]; then
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Validate that a Foundry-encrypted keystore + deployer address are configured.
# Deploys use 'forge --account "$KEYSTORE_ACCOUNT" --sender "$DEPLOYER_ADDRESS"';
# Foundry prompts for the keystore password once at broadcast time.
require_keystore_config() {
    if [[ -z "${KEYSTORE_ACCOUNT:-}" ]]; then
        echo -e "${RED}Error: KEYSTORE_ACCOUNT is not set${NC}" >&2
        echo "Run ./setup-deployer-wallet.sh to create an encrypted keystore." >&2
        exit 1
    fi
    local keystore_path="${HOME}/.foundry/keystores/${KEYSTORE_ACCOUNT}"
    if [[ ! -f "$keystore_path" ]]; then
        echo -e "${RED}Error: keystore '$KEYSTORE_ACCOUNT' not found at $keystore_path${NC}" >&2
        echo "Run ./setup-deployer-wallet.sh $KEYSTORE_ACCOUNT to create it." >&2
        exit 1
    fi
    if [[ -z "${DEPLOYER_ADDRESS:-}" ]]; then
        echo -e "${RED}Error: DEPLOYER_ADDRESS is not set${NC}" >&2
        echo "Set it to the address printed by ./setup-deployer-wallet.sh." >&2
        exit 1
    fi
}

usage() {
    echo "Usage: $0 <command> [options]"
    echo ""
    echo "Commands:"
    echo "  deploy <chain-id>      Deploy contracts to specified chain"
    echo "  dry-run <chain-id>     Simulate deployment without broadcasting"
    echo "  preview <chain-id>     Preview deployment addresses without deploying"
    echo "  verify <chain-id>      Verify deployed contracts on block explorer"
    echo "  wire-bundle <chain-id> Write Safe Tx Builder JSON for Router.executor wiring"
    echo "  wire-propose <chain-id> Propose the wiring batch to the Safe Transaction Service"
    echo "  list-chains            List supported chains"
    echo ""
    echo "Environment Variables (auto-loaded from .env):"
    echo "  KEYSTORE_ACCOUNT     Foundry encrypted keystore account name (run ./setup-deployer-wallet.sh)"
    echo "  DEPLOYER_ADDRESS     Deployer address (printed by ./setup-deployer-wallet.sh)"
    echo "  SAFE_ADDRESS         Safe multi-sig address (required for mainnet, optional for testnet)"
    echo "  ROUTER_LIQUIDATOR    Router liquidator address (defaults to Router owner)"
    echo "  <CHAIN>_RPC_URL      RPC URL for the target chain (e.g., ETH_RPC_URL, BASE_RPC_URL)"
    echo "  ETHERSCAN_API_KEY    Etherscan V2 API key (works across all supported chains)"
    echo "  SALT_VERSION         Salt version for CREATE3 addresses (default: v1)"
    echo "  SAFE_PROPOSER_ADDRESS  Safe owner address that signs wire-propose proposals"
    echo "  SAFE_PROPOSER_ACCOUNT  Foundry keystore name for the proposer key"
    echo "  SAFE_PROPOSER_LEDGER   Set to 1 to sign wire-propose with a Ledger"
    echo "  SAFE_API_KEY           Optional Safe API key (raises rate limits)"
    exit 1
}

check_env() {
    local var_name="$1"
    if [[ -z "${!var_name:-}" ]]; then
        echo -e "${RED}Error: $var_name environment variable is not set${NC}"
        exit 1
    fi
}

get_chain_config() {
    local chain_id="$1"
    local field="$2"
    jq -r ".chains[\"$chain_id\"].$field // empty" "$CHAINS_FILE"
}

# Check if chain is a testnet
get_is_testnet() {
    local chain_id="$1"
    local is_testnet
    is_testnet=$(jq -r ".chains[\"$chain_id\"].isTestnet // false" "$CHAINS_FILE")
    [[ "$is_testnet" == "true" ]]
}

# Validate Safe address format and existence on-chain
validate_safe_address() {
    local safe_addr="$1"
    local rpc_url="$2"

    # Check format: 0x followed by 40 hex characters
    if [[ ! "$safe_addr" =~ ^0x[a-fA-F0-9]{40}$ ]]; then
        echo -e "${RED}Error: Invalid SAFE_ADDRESS format${NC}"
        echo "Must be 0x followed by 40 hex characters (e.g., 0x1234...abcd)"
        exit 1
    fi

    # Check Safe exists on-chain
    local code
    code=$(cast code "$safe_addr" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")

    if [[ "$code" == "0x" || -z "$code" ]]; then
        echo -e "${RED}Error: No Safe found at $safe_addr${NC}"
        echo "Verify the address is correct and Safe is deployed on this chain."
        exit 1
    fi
}

# CREATE3 factory address (same on all supported chains)
CREATE3_FACTORY="0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf"

check_create3_factory() {
    local rpc_url="$1"
    local code
    code=$(cast code "$CREATE3_FACTORY" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")

    if [[ "$code" == "0x" || -z "$code" ]]; then
        echo -e "${RED}Error: CREATE3 factory not found at $CREATE3_FACTORY${NC}"
        echo "The CREATE3 factory must be deployed on this chain before running deployments."
        exit 1
    fi
}

list_chains() {
    echo "Supported chains:"
    echo ""
    jq -r '.chains | to_entries[] | "  \(.key): \(.value.displayName) (\(.value.name))"' "$CHAINS_FILE"
}

# Get contracts list from chains.json
get_contracts() {
    jq -r '.contracts[]' "$CHAINS_FILE"
}

# Get contract source path for verification
get_contract_path() {
    local contract="$1"
    case "$contract" in
        ExecutionProxy)
            echo "src/ExecutionProxy.sol:ExecutionProxy"
            ;;
        Router)
            echo "src/Router.sol:Router"
            ;;
        *)
            echo "src/weiroll-helpers/${contract}.sol:${contract}"
            ;;
    esac
}

# Generate deployment registry from broadcast logs
generate_registry() {
    local chain_id="$1"
    local deployer="$2"
    local rpc_url="$3"

    local broadcast_file="$SCRIPT_DIR/broadcast/DeployCreate3.s.sol/$chain_id/run-latest.json"
    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"

    if [[ ! -f "$broadcast_file" ]]; then
        echo -e "${RED}Error: No broadcast logs found at $broadcast_file${NC}"
        echo "Deployment may have failed - check forge output above."
        return 1
    fi

    # Snapshot existing registry so contracts not created in THIS broadcast keep
    # their historical txHash/blockNumber. Without this, a single-contract
    # follow-up run (e.g. ExecutionProxy redeploy at a new salt) would clobber
    # Router/helper provenance with the new tx's hash.
    local prev_registry_json="{}"
    if [[ -f "$registry_file" ]]; then
        prev_registry_json=$(cat "$registry_file")
        echo -e "${YELLOW}Warning: Overwriting existing deployments/$chain_id.json${NC}"
    fi

    local chain_name
    chain_name=$(get_chain_config "$chain_id" "displayName")
    local salt_version="${SALT_VERSION:-v1}"
    local owner="${SAFE_ADDRESS:-$deployer}"
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Build contracts object from broadcast
    local contracts_json="{"
    local first=true

    while IFS= read -r contract; do
        # ExecutionProxy uses a pinned namespace independent of SALT_VERSION;
        # see DeployCreate3.s.sol EXECUTION_PROXY_SALT_NAMESPACE. Its bytecode
        # changes with each VM dispatcher fix; current bump .v2 -> .v3 lands
        # FLAG_DATA support (spec 00001-CHORE-vm-flag-data).
        local packed
        if [[ "$contract" == "ExecutionProxy" ]]; then
            packed="infrared.contracts.executionproxy.v3"
        else
            packed="infrared.contracts.${salt_version}${contract}"
        fi
        local salt
        salt=$(cast keccak "$packed")

        # Find the contract creation in broadcast (look for CREATE3 factory calls)
        # The deployed address is predicted by CREATE3
        local predicted_addr
        predicted_addr=$(cast call "$CREATE3_FACTORY" "getDeployed(address,bytes32)(address)" "$deployer" "$salt" --rpc-url "$rpc_url" 2>/dev/null || echo "")

        if [[ -z "$predicted_addr" || "$predicted_addr" == "0x0000000000000000000000000000000000000000" ]]; then
            echo -e "${YELLOW}Warning: Could not determine address for $contract${NC}"
            continue
        fi

        # Skip the registry row when no code is deployed at the predicted
        # address. CREATE3 hands out a deterministic address whether or
        # not the contract was actually deployed on this chain, so this
        # check is what lets conditionally-deployed contracts (today:
        # UniswapV4SwapHelpers on chains with no Universal Router config)
        # stay out of the per-chain registry without special-casing.
        # Probe with retries: a transient RPC error must not silently drop a
        # deployed contract from the registry (bit us on Arbitrum, where
        # UniswapV4SwapHelpers was live but a single failed probe skipped it).
        local code_at_addr="0x"
        local probe_attempt
        for probe_attempt in 1 2 3; do
            code_at_addr=$(cast code "$predicted_addr" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")
            [[ "$code_at_addr" != "0x" && -n "$code_at_addr" ]] && break
            [[ "$probe_attempt" -lt 3 ]] && sleep 2
        done
        if [[ "$code_at_addr" == "0x" || -z "$code_at_addr" ]]; then
            echo -e "${YELLOW}Skipping $contract: no code at $predicted_addr on chain $chain_id${NC}"
            continue
        fi

        # Match the contract against this broadcast's inner CREATE3 deploys
        # (forge records them under transactions[].additionalContracts[]). If
        # absent, the contract was already on-chain before this run — preserve
        # the previous registry entry instead of stamping it with this run's tx.
        local tx_hash
        tx_hash=$(jq -r --arg addr "${predicted_addr,,}" '
            .transactions[]? as $tx
            | ($tx.additionalContracts // [])[]
            | select(.address != null and (.address | ascii_downcase) == $addr)
            | $tx.hash // empty' "$broadcast_file" | head -1)

        local block_number=""
        if [[ -n "$tx_hash" ]]; then
            block_number=$(jq -r --arg hash "$tx_hash" '.receipts[]? | select(.transactionHash == $hash) | .blockNumber // empty' "$broadcast_file" | head -1)
        else
            # Not deployed in this run — preserve prior provenance.
            tx_hash=$(printf '%s' "$prev_registry_json" | jq -r --arg c "$contract" '.contracts[$c].txHash // empty')
            block_number=$(printf '%s' "$prev_registry_json" | jq -r --arg c "$contract" '.contracts[$c].blockNumber // empty')
        fi

        # Convert hex block number to decimal if needed
        if [[ "$block_number" =~ ^0x ]]; then
            block_number=$((block_number))
        fi

        if [[ "$first" == "true" ]]; then
            first=false
        else
            contracts_json+=","
        fi

        contracts_json+="\"$contract\":{\"address\":\"$predicted_addr\",\"salt\":\"$salt\",\"verified\":false"
        if [[ -n "$tx_hash" ]]; then
            contracts_json+=",\"txHash\":\"$tx_hash\""
        fi
        if [[ -n "$block_number" && "$block_number" != "null" ]]; then
            contracts_json+=",\"blockNumber\":$block_number"
        fi
        contracts_json+="}"
    done < <(get_contracts)

    contracts_json+="}"

    # Write registry file
    cat > "$registry_file" << EOF
{
  "chainId": $chain_id,
  "chainName": "$chain_name",
  "deployedAt": "$timestamp",
  "deployer": "$deployer",
  "owner": "$owner",
  "contracts": $contracts_json,
  "create3Factory": "$CREATE3_FACTORY"
}
EOF

    echo ""
    echo -e "${GREEN}Registry generated: $registry_file${NC}"
}

# Pre-deploy guard for UniswapV4SwapHelpers (Nethermind NM-1048): the helper
# reproduces Uniswap's ExactInputSingleParams struct locally, and some chains
# host two Universal Router revisions with different struct shapes. Run the
# chain's fork layout test against the exact router DeployCreate3 pins so a
# wrong pin fails here, not after the helper is deployed. The test forks from
# the chain's rpcEnv (already required by deploy/dry-run) and must PASS; a
# skipped test (no RPC) is treated as a failure so the gate cannot be bypassed
# silently. Chains with no Universal Router pin skip UniswapV4SwapHelpers and
# therefore skip this gate.
check_v4_layout() {
    local chain_id="$1"
    local test_name
    case "$chain_id" in
        1) test_name="test_Layout_Ethereum" ;;
        8453) test_name="test_Layout_Base" ;;
        42161) test_name="test_Layout_ArbitrumOne" ;;
        *)
            echo "No Universal Router pinned for chain $chain_id; UniswapV4SwapHelpers is skipped, so is the layout guard."
            return 0
            ;;
    esac

    echo "=== Checking UniswapV4SwapHelpers struct layout against the pinned Universal Router ==="
    local out
    if ! out=$(cd "$SCRIPT_DIR" && forge test --match-contract UniswapV4SwapHelpersForkTest --match-test "$test_name" 2>&1) \
        || ! grep -q "\[PASS\] $test_name" <<< "$out"; then
        echo "$out" | tail -n 25
        echo -e "${RED}Error: $test_name did not pass. The helper's ExactInputSingleParams layout does not match the pinned Universal Router on chain $chain_id (or the fork could not run).${NC}"
        exit 1
    fi
    echo -e "${GREEN}Layout guard passed ($test_name)${NC}"
    echo ""
}

deploy() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${GREEN}Deploying to $display_name (Chain ID: $chain_id)${NC}"

    require_keystore_config

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Determine owner address based on testnet/mainnet
    local owner_address
    if get_is_testnet "$chain_id"; then
        if [[ -n "${SAFE_ADDRESS:-}" ]]; then
            validate_safe_address "$SAFE_ADDRESS" "$rpc_url"
            owner_address="$SAFE_ADDRESS"
            echo "Owner: $owner_address (Safe multi-sig)"
        else
            owner_address="$DEPLOYER_ADDRESS"
            echo "Owner: $owner_address (deployer EOA - testnet)"
        fi
    else
        if [[ -z "${SAFE_ADDRESS:-}" ]]; then
            echo -e "${RED}Error: Mainnet deployment requires SAFE_ADDRESS${NC}"
            echo "Set SAFE_ADDRESS in .env to your Safe multi-sig address."
            exit 1
        fi
        validate_safe_address "$SAFE_ADDRESS" "$rpc_url"
        owner_address="$SAFE_ADDRESS"
        echo "Owner: $owner_address (Safe multi-sig)"
    fi

    check_create3_factory "$rpc_url"
    check_v4_layout "$chain_id"

    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"
    echo "Deployer: $DEPLOYER_ADDRESS (keystore: $KEYSTORE_ACCOUNT)"

    export OWNER_ADDRESS="$owner_address"
    export ROUTER_OWNER="${ROUTER_OWNER:-$owner_address}"
    export ROUTER_LIQUIDATOR="${ROUTER_LIQUIDATOR:-$owner_address}"
    echo "Router owner: $ROUTER_OWNER"
    echo "Router liquidator: $ROUTER_LIQUIDATOR"
    echo ""
    echo -e "${YELLOW}Foundry will prompt for the keystore password before broadcasting${NC}"

    cd "$SCRIPT_DIR"
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --account "$KEYSTORE_ACCOUNT" \
        --sender "$DEPLOYER_ADDRESS" \
        --broadcast \
        -vvv

    echo ""
    echo -e "${GREEN}Deployment complete!${NC}"

    generate_registry "$chain_id" "$DEPLOYER_ADDRESS" "$rpc_url"

    # Auto-generate the Safe Tx Builder bundle for the Router.executor wiring
    # follow-up. Skipped when there's no Safe (testnet EOA-owner case) — the
    # deployer can broadcast the two txs directly without going through a Safe.
    if [[ -n "${SAFE_ADDRESS:-}" ]]; then
        echo ""
        wire_bundle "$chain_id"
        # With a proposer configured, also push the batch straight into the
        # owners' Safe app queue. Non-fatal: the Tx Builder bundle above is
        # the fallback and the broadcast already succeeded.
        if [[ -n "${SAFE_PROPOSER_ADDRESS:-}" ]]; then
            echo ""
            wire_propose "$chain_id" \
                || echo -e "${YELLOW}wire-propose failed; import the Tx Builder bundle instead or rerun '$0 wire-propose $chain_id'${NC}"
        fi
    fi

    echo ""
    echo "Next steps:"
    echo "  1. Run '$0 verify $chain_id' to verify contracts on block explorer"
    echo ""
    echo -e "${YELLOW}[ACTION REQUIRED] Router.executor wiring${NC}"
    if [[ "$DEPLOYER_ADDRESS" == "$ROUTER_OWNER" ]]; then
        echo "  Deployer broadcast router.setPendingExecutor(executionProxy) during run()."
        echo "  The Router owner multisig must still send router.acceptExecutor() before"
        echo "  the Router can serve swaps on $display_name."
    else
        echo "  Router owner ($ROUTER_OWNER) must send two txs from the multisig on $display_name:"
        echo "    1) router.setPendingExecutor(executionProxy)"
        echo "    2) router.acceptExecutor()"
        if [[ -n "${SAFE_ADDRESS:-}" ]]; then
            echo "  Bundle written to tmp/wire-executor-$chain_name.json (Safe Tx Builder import)."
        fi
    fi
}

preview() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${YELLOW}Previewing addresses for $display_name (Chain ID: $chain_id)${NC}"

    require_keystore_config

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"
    echo "Deployer: $DEPLOYER_ADDRESS"

    export ROUTER_OWNER="${ROUTER_OWNER:-${SAFE_ADDRESS:-$DEPLOYER_ADDRESS}}"
    export ROUTER_LIQUIDATOR="${ROUTER_LIQUIDATOR:-$DEPLOYER_ADDRESS}"
    echo "Router owner: $ROUTER_OWNER"
    echo "Router liquidator: $ROUTER_LIQUIDATOR"

    cd "$SCRIPT_DIR"
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --sig "preview()" \
        --sender "$DEPLOYER_ADDRESS" \
        -vvv
}

dry_run() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${YELLOW}Dry-run deployment for $display_name (Chain ID: $chain_id)${NC}"

    require_keystore_config

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    check_create3_factory "$rpc_url"
    check_v4_layout "$chain_id"

    local salt_version="${SALT_VERSION:-v1}"
    echo "Salt version: $salt_version"
    echo "Deployer: $DEPLOYER_ADDRESS"

    export ROUTER_OWNER="${ROUTER_OWNER:-${SAFE_ADDRESS:-$DEPLOYER_ADDRESS}}"
    export ROUTER_LIQUIDATOR="${ROUTER_LIQUIDATOR:-$DEPLOYER_ADDRESS}"
    echo "Router owner: $ROUTER_OWNER"
    echo "Router liquidator: $ROUTER_LIQUIDATOR"
    echo ""

    cd "$SCRIPT_DIR"
    echo "=== Compiling contracts ==="
    if forge build; then
        echo -e "${GREEN}Compilation successful${NC}"
    else
        echo -e "${RED}Compilation failed${NC}"
        exit 1
    fi
    echo ""

    echo "=== Simulating deployment ==="
    forge script script/DeployCreate3.s.sol:DeployCreate3 \
        --rpc-url "$rpc_url" \
        --sender "$DEPLOYER_ADDRESS" \
        -vvv

    echo ""
    echo -e "${GREEN}Dry-run complete!${NC}"
    echo ""
    echo "To execute the actual deployment, run:"
    echo "  $0 deploy $chain_id"
}

verify() {
    local chain_id="$1"

    # Validate chain
    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi

    local display_name
    display_name=$(get_chain_config "$chain_id" "displayName")
    echo -e "${GREEN}Verifying contracts on $display_name${NC}"

    # Get API key env var
    local api_key_env
    api_key_env=$(get_chain_config "$chain_id" "explorer.apiKeyEnv")
    check_env "$api_key_env"
    local api_key="${!api_key_env}"

    local rpc_env
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    local rpc_url="${!rpc_env}"

    # Get explorer API URL
    local api_url
    api_url=$(get_chain_config "$chain_id" "explorer.apiUrl")

    # Read deployment registry if exists
    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"
    if [[ ! -f "$registry_file" ]]; then
        echo -e "${YELLOW}Warning: No deployment registry found at $registry_file${NC}"
        echo "Please create the registry file with deployed addresses first."
        exit 1
    fi

    cd "$SCRIPT_DIR"

    # Router constructor args are (address _owner, address _liquidator). Fall back to deployer
    # when ROUTER_OWNER / ROUTER_LIQUIDATOR env vars are unset (matches run() default).
    local router_owner="${ROUTER_OWNER:-${OWNER_ADDRESS:-$(jq -r '.owner' "$registry_file")}}"
    local router_liquidator="${ROUTER_LIQUIDATOR:-$router_owner}"

    # Universal Router 2.1.1 addresses, mirrored from
    # script/DeployCreate3.sol getUniversalRouter(). Needed here for the
    # UniswapV4SwapHelpers constructor-args ABI encoding at verify time.
    local universal_router=""
    case "$chain_id" in
        1) universal_router="0x4C82D1fBFe28C977cBB58D8C7FF8FCF9F70a2cCA" ;;
        8453) universal_router="0xFdf682F51FE81Aa4898F0AE2163d8A55c127fbC7" ;;
        42161) universal_router="0x8B844f885672f333Bc0042cB669255f93a4C1E6b" ;;
    esac
    local permit2_addr="0x000000000022D473030F116dDEE9F6B43aC78BA3"

    # Verify all contracts from chains.json
    while IFS= read -r contract; do
        local addr
        addr=$(jq -r ".contracts.${contract}.address // empty" "$registry_file")
        local path
        path=$(get_contract_path "$contract")

        # Skip contracts that aren't in this chain's registry (e.g.
        # UniswapV4SwapHelpers on a testnet that skipped deployment).
        if [[ -z "$addr" || "$addr" == "null" ]]; then
            echo -e "${YELLOW}Skipping $contract: not present in registry for chain $chain_id${NC}"
            continue
        fi

        echo "Verifying $contract at $addr..."

        # Build per-contract `forge verify-contract` args. Router and
        # UniswapV4SwapHelpers carry constructor immutables that need
        # ABI-encoding; ExecutionProxy and the stateless helpers do
        # not. Run the same `forge verify-contract … --watch` invocation
        # in every branch — exit 0 means Etherscan accepted (newly
        # verified OR already verified, both fine), non-zero means a
        # real failure (constructor args mismatch, no code at address,
        # network drop).
        local verify_ok=0
        if [[ "$contract" == "Router" ]]; then
            # Router constructor: (address owner, address liquidator)
            forge verify-contract "$addr" "$path" \
                --chain-id "$chain_id" \
                --verifier-url "$api_url" \
                --etherscan-api-key "$api_key" \
                --constructor-args "$(cast abi-encode 'constructor(address,address)' "$router_owner" "$router_liquidator")" \
                --watch && verify_ok=1
        elif [[ "$contract" == "UniswapV4SwapHelpers" ]]; then
            # UniswapV4SwapHelpers constructor:
            # (IUniversalRouter universalRouter, IPermit2 permit2)
            if [[ -z "$universal_router" ]]; then
                echo -e "${YELLOW}Skipping $contract verification: no Universal Router address known for chain $chain_id${NC}"
                continue
            fi
            forge verify-contract "$addr" "$path" \
                --chain-id "$chain_id" \
                --verifier-url "$api_url" \
                --etherscan-api-key "$api_key" \
                --constructor-args "$(cast abi-encode 'constructor(address,address)' "$universal_router" "$permit2_addr")" \
                --watch && verify_ok=1
        else
            # ExecutionProxy (stateless post-refactor) + Weiroll helpers
            # have no constructor args.
            forge verify-contract "$addr" "$path" \
                --chain-id "$chain_id" \
                --verifier-url "$api_url" \
                --etherscan-api-key "$api_key" \
                --watch && verify_ok=1
        fi

        if [[ $verify_ok -eq 1 ]]; then
            # Etherscan accepted the source — flip the local
            # bookkeeping flag so deployments/<chain>.json matches
            # on-chain truth. Without this update the field stays
            # stuck at the deploy-time `false` even though Etherscan
            # reports the contract as verified.
            local tmp
            tmp=$(mktemp)
            if jq --arg c "$contract" '.contracts[$c].verified = true' "$registry_file" > "$tmp"; then
                mv "$tmp" "$registry_file"
                echo -e "${GREEN}  -> set .contracts.$contract.verified = true in $registry_file${NC}"
            else
                rm -f "$tmp"
                echo -e "${YELLOW}  -> failed to update $registry_file for $contract (verification on Etherscan still landed)${NC}"
            fi
        else
            echo -e "${YELLOW}$contract verification failed (or transient verifier error) — registry .verified flag unchanged${NC}"
        fi
    done < <(get_contracts)

    echo ""
    echo -e "${GREEN}Verification complete!${NC}"
}

# Write a Safe Tx Builder JSON bundle for the Router.executor wiring follow-up:
#   1) router.setPendingExecutor(executionProxy)
#   2) router.acceptExecutor()
# Reads addresses from deployments/<chainId>.json (must exist) and SAFE_ADDRESS
# from env. Bundle lands in tmp/wire-executor-<slug>.json and is meant to be
# imported into the Safe app's Transaction Builder.
wire_bundle() {
    local chain_id="$1"

    local chain_name display_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        list_chains
        exit 1
    fi
    display_name=$(get_chain_config "$chain_id" "displayName")

    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"
    if [[ ! -f "$registry_file" ]]; then
        echo -e "${RED}Error: $registry_file not found. Run '$0 deploy $chain_id' first.${NC}"
        exit 1
    fi

    local router_addr executor_addr
    router_addr=$(jq -r '.contracts.Router.address // empty' "$registry_file")
    executor_addr=$(jq -r '.contracts.ExecutionProxy.address // empty' "$registry_file")
    if [[ -z "$router_addr" || -z "$executor_addr" ]]; then
        echo -e "${RED}Error: Router or ExecutionProxy address missing in $registry_file${NC}"
        exit 1
    fi

    local safe_addr="${SAFE_ADDRESS:-}"
    if [[ -z "$safe_addr" ]]; then
        echo -e "${RED}Error: SAFE_ADDRESS not set (in .env or env)${NC}"
        exit 1
    fi

    local set_pending_data accept_data
    set_pending_data=$(cast calldata "setPendingExecutor(address)" "$executor_addr")
    accept_data=$(cast calldata "acceptExecutor()")

    local now_ms
    now_ms=$(( $(date +%s) * 1000 ))

    mkdir -p "$SCRIPT_DIR/tmp"
    local out_file="$SCRIPT_DIR/tmp/wire-executor-$chain_name.json"

    cat > "$out_file" << EOF
{
  "version": "1.0",
  "chainId": "$chain_id",
  "createdAt": $now_ms,
  "meta": {
    "name": "Wire Router executor ($display_name)",
    "description": "setPendingExecutor + acceptExecutor for ExecutionProxy $executor_addr",
    "txBuilderVersion": "1.16.5",
    "createdFromSafeAddress": "$safe_addr",
    "createdFromOwnerAddress": ""
  },
  "transactions": [
    {
      "to": "$router_addr",
      "value": "0",
      "data": "$set_pending_data",
      "contractMethod": null,
      "contractInputsValues": null
    },
    {
      "to": "$router_addr",
      "value": "0",
      "data": "$accept_data",
      "contractMethod": null,
      "contractInputsValues": null
    }
  ]
}
EOF

    echo -e "${GREEN}Wrote $out_file${NC}"
    echo "  Router:         $router_addr"
    echo "  ExecutionProxy: $executor_addr"
    echo "  Safe:           $safe_addr"
    echo ""
    echo "Import this JSON into the Safe app:"
    echo "  app.safe.global -> Apps -> Transaction Builder -> 'Load' (upload JSON)"
}

# Canonical Safe MultiSendCallOnly v1.4.1 (matches the Safe 1.4.1 singleton our
# multisig runs). Batches setPendingExecutor + acceptExecutor into one Safe tx
# via DELEGATECALL so signers approve a single transaction. On the Safe tx
# service's trusted-delegatecall list, so the UI won't flag the proposal.
MULTISEND_CALL_ONLY="0x9641d764fc13c8B624c04430C7356C1C7C8102e2"

# Propose the Router.executor wiring batch directly to the Safe Transaction
# Service so it lands in every owner's Safe app queue -- no manual Tx Builder
# JSON import. Signing threshold still applies; this only automates proposal.
#
# Required env:
#   SAFE_ADDRESS            the Safe (Router owner)
#   SAFE_PROPOSER_ADDRESS   Safe owner address the proposal is signed with
#   SAFE_PROPOSER_ACCOUNT   Foundry keystore name holding that key, OR
#   SAFE_PROPOSER_LEDGER=1  sign with a Ledger instead (eth_sign flow)
# Optional:
#   SAFE_API_KEY            Safe API key (unauthenticated: 2 RPS / 5k per month)
#   SAFE_PROPOSE_DRY=1      build + print the proposal, skip signing and POST
wire_propose() {
    local chain_id="$1"

    local chain_name
    chain_name=$(get_chain_config "$chain_id" "name")
    if [[ -z "$chain_name" ]]; then
        echo -e "${RED}Error: Chain ID $chain_id not found in chains.json${NC}"
        return 1
    fi

    local short_name
    short_name=$(get_chain_config "$chain_id" "safeShortName")
    if [[ -z "$short_name" ]]; then
        echo -e "${RED}Error: no safeShortName for chain $chain_id in chains.json${NC}"
        return 1
    fi
    local svc="https://api.safe.global/tx-service/$short_name/api"

    local registry_file="$DEPLOYMENTS_DIR/$chain_id.json"
    if [[ ! -f "$registry_file" ]]; then
        echo -e "${RED}Error: $registry_file not found. Run '$0 deploy $chain_id' first.${NC}"
        return 1
    fi

    local safe_addr="${SAFE_ADDRESS:-}"
    if [[ -z "$safe_addr" ]]; then
        echo -e "${RED}Error: SAFE_ADDRESS not set${NC}"
        return 1
    fi
    local proposer="${SAFE_PROPOSER_ADDRESS:-}"
    if [[ -z "$proposer" && -z "${SAFE_PROPOSE_DRY:-}" ]]; then
        echo -e "${RED}Error: SAFE_PROPOSER_ADDRESS not set (must be a Safe owner)${NC}"
        return 1
    fi

    local rpc_env rpc_url
    rpc_env=$(get_chain_config "$chain_id" "rpcEnv")
    check_env "$rpc_env"
    rpc_url="${!rpc_env}"

    local router_addr executor_addr
    router_addr=$(jq -r '.contracts.Router.address // empty' "$registry_file")
    executor_addr=$(jq -r '.contracts.ExecutionProxy.address // empty' "$registry_file")
    if [[ -z "$router_addr" || -z "$executor_addr" ]]; then
        echo -e "${RED}Error: Router or ExecutionProxy address missing in $registry_file${NC}"
        return 1
    fi

    # Idempotence: nothing to propose when the executor is already wired.
    local current_executor
    current_executor=$(cast call "$router_addr" "executor()(address)" --rpc-url "$rpc_url" 2>/dev/null || echo "")
    if [[ "${current_executor,,}" == "${executor_addr,,}" ]]; then
        echo -e "${GREEN}Router.executor already set to $executor_addr on chain $chain_id -- nothing to propose${NC}"
        return 0
    fi

    # MultiSendCallOnly must exist on the target chain (canonical deploy).
    local ms_code
    ms_code=$(cast code "$MULTISEND_CALL_ONLY" --rpc-url "$rpc_url" 2>/dev/null || echo "0x")
    if [[ "$ms_code" == "0x" || -z "$ms_code" ]]; then
        echo -e "${RED}Error: MultiSendCallOnly not found at $MULTISEND_CALL_ONLY on chain $chain_id${NC}"
        return 1
    fi

    # Inner calls, then the packed MultiSend encoding:
    # each tx = operation(uint8=0 CALL) ++ to(20) ++ value(uint256=0) ++ dataLen(uint256) ++ data
    local set_pending_data accept_data
    set_pending_data=$(cast calldata "setPendingExecutor(address)" "$executor_addr") || return 1
    accept_data=$(cast calldata "acceptExecutor()") || return 1

    local tx1 tx2 ms_inner ms_data
    tx1=$(cast abi-encode --packed "f(uint8,address,uint256,uint256,bytes)" \
        0 "$router_addr" 0 $(( (${#set_pending_data} - 2) / 2 )) "$set_pending_data") || return 1
    tx2=$(cast abi-encode --packed "f(uint8,address,uint256,uint256,bytes)" \
        0 "$router_addr" 0 $(( (${#accept_data} - 2) / 2 )) "$accept_data") || return 1
    ms_inner=$(cast concat-hex "$tx1" "$tx2") || return 1
    ms_data=$(cast calldata "multiSend(bytes)" "$ms_inner") || return 1

    # Next nonce = max(on-chain nonce, highest queued nonce + 1) so we never
    # collide with an already-proposed tx waiting on signatures.
    local chain_nonce queued_nonce nonce queue_count
    chain_nonce=$(cast call "$safe_addr" "nonce()(uint256)" --rpc-url "$rpc_url") || return 1
    local auth_args=()
    if [[ -n "${SAFE_API_KEY:-}" ]]; then
        auth_args=(-H "Authorization: Bearer $SAFE_API_KEY")
    fi
    local queue_json
    queue_json=$(curl -sf "${auth_args[@]}" \
        "$svc/v1/safes/$safe_addr/multisig-transactions/?executed=false&limit=1&ordering=-nonce" || echo "{}")
    queued_nonce=$(printf '%s' "$queue_json" | jq -r '.results[0].nonce // empty')
    queue_count=$(printf '%s' "$queue_json" | jq -r '.count // 0')
    nonce="$chain_nonce"
    if [[ -n "$queued_nonce" && "$queued_nonce" -ge "$chain_nonce" ]]; then
        nonce=$((queued_nonce + 1))
        echo -e "${YELLOW}Safe queue has $queue_count pending tx(s); proposing at nonce $nonce.${NC}"
        echo -e "${YELLOW}Check the queue for an existing wiring proposal before signing.${NC}"
    fi

    # Ask the Safe itself for the EIP-712 tx hash -- version-proof vs local math.
    local safe_tx_hash
    safe_tx_hash=$(cast call "$safe_addr" \
        "getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)" \
        "$MULTISEND_CALL_ONLY" 0 "$ms_data" 1 0 0 0 \
        0x0000000000000000000000000000000000000000 \
        0x0000000000000000000000000000000000000000 \
        "$nonce" --rpc-url "$rpc_url") || return 1

    echo "Safe:            $safe_addr ($short_name)"
    echo "Router:          $router_addr"
    echo "ExecutionProxy:  $executor_addr"
    echo "MultiSend batch: setPendingExecutor + acceptExecutor (1 signature per signer)"
    echo "Nonce:           $nonce"
    echo "SafeTxHash:      $safe_tx_hash"

    if [[ -n "${SAFE_PROPOSE_DRY:-}" ]]; then
        echo ""
        echo -e "${YELLOW}Dry mode: skipping signature + POST. Payload:${NC}"
        jq -n --arg safe "$safe_addr" --arg to "$MULTISEND_CALL_ONLY" --arg data "$ms_data" \
            --arg hash "$safe_tx_hash" --argjson nonce "$nonce" \
            '{safe: $safe, to: $to, value: "0", data: $data, operation: 1,
              gasToken: "0x0000000000000000000000000000000000000000",
              safeTxGas: "0", baseGas: "0", gasPrice: "0",
              refundReceiver: "0x0000000000000000000000000000000000000000",
              nonce: $nonce, contractTransactionHash: $hash}'
        return 0
    fi

    # Warn (not fail) when the proposer is not an owner -- registered service
    # delegates are also allowed to propose.
    local is_owner
    is_owner=$(cast call "$safe_addr" "isOwner(address)(bool)" "$proposer" --rpc-url "$rpc_url" 2>/dev/null || echo "false")
    if [[ "$is_owner" != "true" ]]; then
        echo -e "${YELLOW}Warning: $proposer is not a Safe owner; proposal will be rejected unless it is a registered delegate${NC}"
    fi

    # Sign the safeTxHash. Keystore path signs the raw EIP-712 digest (v 27/28).
    # Ledger cannot sign raw digests, so it signs via eth_sign (EIP-191 prefix)
    # and we bump v by 4 -- the Safe convention marking a prefixed signature.
    local sig
    if [[ -n "${SAFE_PROPOSER_LEDGER:-}" ]]; then
        echo "Signing with Ledger (confirm on device)..."
        sig=$(cast wallet sign --ledger "$safe_tx_hash") || return 1
        local v=$((16#${sig:130:2} + 4))
        sig="0x${sig:2:128}$(printf '%02x' "$v")"
    elif [[ -n "${SAFE_PROPOSER_ACCOUNT:-}" ]]; then
        echo "Signing with keystore '$SAFE_PROPOSER_ACCOUNT' (password prompt follows)..."
        sig=$(cast wallet sign --no-hash --account "$SAFE_PROPOSER_ACCOUNT" "$safe_tx_hash") || return 1
    else
        echo -e "${RED}Error: set SAFE_PROPOSER_ACCOUNT (keystore) or SAFE_PROPOSER_LEDGER=1${NC}"
        return 1
    fi

    local payload http_code response
    payload=$(jq -n --arg safe "$safe_addr" --arg to "$MULTISEND_CALL_ONLY" --arg data "$ms_data" \
        --arg hash "$safe_tx_hash" --arg sender "$proposer" --arg sig "$sig" --argjson nonce "$nonce" \
        '{safe: $safe, to: $to, value: "0", data: $data, operation: 1,
          gasToken: "0x0000000000000000000000000000000000000000",
          safeTxGas: "0", baseGas: "0", gasPrice: "0",
          refundReceiver: "0x0000000000000000000000000000000000000000",
          nonce: $nonce, contractTransactionHash: $hash,
          sender: $sender, signature: $sig, origin: "infrared deploy.sh wire-propose"}')

    response=$(curl -s -w '\n%{http_code}' "${auth_args[@]}" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$svc/v1/safes/$safe_addr/multisig-transactions/")
    http_code=$(printf '%s' "$response" | tail -1)

    if [[ "$http_code" == "201" || "$http_code" == "200" ]]; then
        echo ""
        echo -e "${GREEN}Proposal submitted to the Safe Transaction Service${NC}"
        echo "Signers can review + confirm in the queue:"
        echo "  https://app.safe.global/transactions/queue?safe=$short_name:$safe_addr"
        echo "After both wiring txs execute, confirm with:"
        echo "  cast call $router_addr 'executor()(address)' --rpc-url \$${rpc_env}"
    else
        echo -e "${RED}Proposal failed (HTTP $http_code):${NC}"
        printf '%s\n' "$response" | head -n -1
        return 1
    fi
}

# Main
if [[ $# -lt 1 ]]; then
    usage
fi

case "$1" in
    deploy)
        [[ $# -lt 2 ]] && usage
        deploy "$2"
        ;;
    dry-run)
        [[ $# -lt 2 ]] && usage
        dry_run "$2"
        ;;
    preview)
        [[ $# -lt 2 ]] && usage
        preview "$2"
        ;;
    verify)
        [[ $# -lt 2 ]] && usage
        verify "$2"
        ;;
    wire-bundle)
        [[ $# -lt 2 ]] && usage
        wire_bundle "$2"
        ;;
    wire-propose)
        [[ $# -lt 2 ]] && usage
        wire_propose "$2"
        ;;
    list-chains)
        list_chains
        ;;
    *)
        usage
        ;;
esac
