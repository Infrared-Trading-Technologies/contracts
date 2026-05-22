// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { ExecutionProxy } from "../src/ExecutionProxy.sol";
import { Router } from "../src/Router.sol";
import { Tupler } from "../src/weiroll-helpers/Tupler.sol";
import { Integer } from "../src/weiroll-helpers/Integer.sol";
import { Bytes32 } from "../src/weiroll-helpers/Bytes32.sol";
import { BlockchainInfo } from "../src/weiroll-helpers/BlockchainInfo.sol";
import { ArraysConverter } from "../src/weiroll-helpers/ArraysConverter.sol";
import { MathHelpers } from "../src/weiroll-helpers/MathHelpers.sol";
import { SignedMathHelpers } from "../src/weiroll-helpers/SignedMathHelpers.sol";

/// @notice Interface for ZeframLou's CREATE3 Factory
/// @dev Deployed at 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf on all supported chains
interface ICREATE3Factory {
    /// @notice Deploys a contract using CREATE3
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @param creationCode The creation code of the contract to deploy
    /// @return deployed The address of the deployed contract
    function deploy(bytes32 salt, bytes memory creationCode) external payable returns (address deployed);

    /// @notice Predicts the address of a deployed contract
    /// @param deployer The deployer account that will call deploy()
    /// @param salt The deployer-specific salt for determining the deployed contract's address
    /// @return deployed The address of the contract that will be deployed
    function getDeployed(address deployer, bytes32 salt) external view returns (address deployed);
}

/// @title DeployCreate3
/// @notice Idempotent deployment script using CREATE3 for deterministic addresses
/// @dev Uses ZeframLou's CREATE3 factory for consistent addresses across chains
contract DeployCreate3 is Script {
    // CREATE3 Factory - same address on all supported chains
    address public constant CREATE3_FACTORY = 0x9fBB3DF7C40Da2e5A0dE984fFE2CCB7C47cd0ABf;

    // Default salt version (can be overridden via SALT_VERSION env var)
    string public constant DEFAULT_SALT_VERSION = "v1";

    // Contract names for salt generation
    string public constant EXECUTION_PROXY = "ExecutionProxy";
    string public constant ROUTER = "Router";
    string public constant TUPLER = "Tupler";
    string public constant INTEGER = "Integer";
    string public constant BYTES32 = "Bytes32";
    string public constant BLOCKCHAIN_INFO = "BlockchainInfo";
    string public constant ARRAYS_CONVERTER = "ArraysConverter";
    string public constant MATH_HELPERS = "MathHelpers";
    string public constant SIGNED_MATH_HELPERS = "SignedMathHelpers";

    // ExecutionProxy bytecode changes every time the Weiroll VM dispatcher does
    // (extended-command decoder, dispatcher, flag layout, FLAG_DATA, etc.). Its
    // salt is pinned to a namespace independent of `SALT_VERSION` so each fixed
    // bytecode lands at a fresh CREATE3 address while Router and helper
    // deployments stay on their existing v1 addresses. Current bump: .v2 -> .v3
    // accompanies FLAG_DATA dispatcher support (spec 00001).
    string public constant EXECUTION_PROXY_SALT_NAMESPACE = "infrared.contracts.executionproxy.v3";

    // CREATE3 proxy bytecode hash (from solmate/ZeframLou CREATE3). Used to predict the deployed
    // address locally when no RPC is available (e.g. CI-less preview).
    bytes32 internal constant CREATE3_PROXY_BYTECODE_HASH = keccak256(hex"67363d3d37363d34f03d5260086018f3");

    // Deployment results
    struct DeploymentResult {
        address executionProxy;
        address router;
        address tupler;
        address integer;
        address bytes32Helper;
        address blockchainInfo;
        address arraysConverter;
        address mathHelpers;
        address signedMathHelpers;
        bool[] deployed; // true if newly deployed, false if already existed (indexed in enumeration order)
        bool routerDeployed; // true if Router was newly deployed in this run
    }

    /// @notice Gets the salt version from env var or returns default
    /// @return The salt version string (e.g., "v1", "v2")
    function getSaltVersion() public view returns (string memory) {
        try vm.envString("SALT_VERSION") returns (string memory version) {
            return version;
        } catch {
            return DEFAULT_SALT_VERSION;
        }
    }

    /// @notice Gets the Router owner address from env var or returns msg.sender
    /// @dev Router owner is an Ownable2Step multisig in production. Falls back to deployer when
    ///      unset so dev / preview flows work without extra env plumbing.
    function getRouterOwner() public view returns (address) {
        try vm.envAddress("ROUTER_OWNER") returns (address owner) {
            return owner;
        } catch {
            try vm.envAddress("OWNER_ADDRESS") returns (address owner) {
                return owner;
            } catch {
                return msg.sender;
            }
        }
    }

    /// @notice Gets the Router liquidator address from env var or returns msg.sender
    /// @dev Router requires a non-zero liquidator at construction; the owner can later call
    ///      `setLiquidator(address(0))` to disable the role.
    function getRouterLiquidator() public view returns (address) {
        try vm.envAddress("ROUTER_LIQUIDATOR") returns (address liq) {
            return liq;
        } catch {
            return msg.sender;
        }
    }

    /// @notice Generates a deterministic salt for a contract
    /// @param contractName The name of the contract
    /// @return The salt to use for CREATE3 deployment
    function getSalt(string memory contractName) public view returns (bytes32) {
        string memory version = getSaltVersion();
        string memory prefix = string.concat("infrared.contracts.", version);
        return keccak256(abi.encodePacked(prefix, contractName));
    }

    /// @notice Pinned CREATE3 salt for ExecutionProxy.
    /// @dev Independent of `SALT_VERSION` because the contract's bytecode changed
    ///      during the Weiroll VM remediation and must land at a fresh address.
    function getExecutionProxySalt() public pure returns (bytes32) {
        return keccak256(bytes(EXECUTION_PROXY_SALT_NAMESPACE));
    }

    /// @notice Predicts the deployment address for a contract
    /// @dev Uses the on-chain factory when available; otherwise reproduces the ZeframLou
    ///      CREATE3 math locally so `preview()` works without an RPC.
    /// @param deployer The deployer address
    /// @param contractName The name of the contract
    /// @return The predicted deployment address
    function predictAddress(address deployer, string memory contractName) public view returns (address) {
        return _predictForSalt(deployer, getSalt(contractName));
    }

    /// @notice Predicts the ExecutionProxy deployment address using its pinned salt.
    function predictExecutionProxyAddress(address deployer) public view returns (address) {
        return _predictForSalt(deployer, getExecutionProxySalt());
    }

    function _predictForSalt(address deployer, bytes32 salt) internal view returns (address) {
        if (isDeployed(CREATE3_FACTORY)) {
            return ICREATE3Factory(CREATE3_FACTORY).getDeployed(deployer, salt);
        }
        return _predictCreate3Address(deployer, salt);
    }

    /// @dev Local reimplementation of ZeframLou CREATE3Factory.getDeployed. The factory namespaces
    ///      salts by hashing `(deployer, salt)` before delegating to solmate's CREATE3 algorithm
    ///      (CREATE2 proxy deploy, then CREATE with nonce 1 from the proxy).
    function _predictCreate3Address(address deployer, bytes32 salt) internal pure returns (address) {
        bytes32 hashedSalt = keccak256(abi.encode(deployer, salt));
        address proxy = address(
            uint160(
                uint256(
                    keccak256(abi.encodePacked(bytes1(0xFF), CREATE3_FACTORY, hashedSalt, CREATE3_PROXY_BYTECODE_HASH))
                )
            )
        );
        return address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", proxy, hex"01")))));
    }

    /// @notice Checks if a contract is already deployed at an address
    /// @param addr The address to check
    /// @return True if code exists at the address
    function isDeployed(address addr) public view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /// @notice Deploys a contract using CREATE3 if not already deployed
    /// @param salt The salt for deployment
    /// @param creationCode The creation code
    /// @param contractName The name for logging
    /// @return deployed The deployed address
    /// @return wasDeployed True if newly deployed
    function deployIfNeeded(bytes32 salt, bytes memory creationCode, string memory contractName)
        internal
        returns (address deployed, bool wasDeployed)
    {
        deployed = ICREATE3Factory(CREATE3_FACTORY).getDeployed(msg.sender, salt);

        if (isDeployed(deployed)) {
            console2.log(string.concat(contractName, " already deployed at:"), deployed);
            return (deployed, false);
        }

        deployed = ICREATE3Factory(CREATE3_FACTORY).deploy(salt, creationCode);
        console2.log(string.concat(contractName, " deployed at:"), deployed);
        return (deployed, true);
    }

    /// @notice Main deployment function
    function run() public returns (DeploymentResult memory result) {
        // Verify CREATE3 factory exists
        require(isDeployed(CREATE3_FACTORY), "CREATE3 factory not found at expected address");

        uint256 chainId = block.chainid;
        address deployer = msg.sender;
        address routerOwner = getRouterOwner();
        address routerLiquidator = getRouterLiquidator();
        string memory saltVersion = getSaltVersion();

        console2.log("Deploying contracts...");
        console2.log("Chain ID:", chainId);
        console2.log("Deployer:", deployer);
        console2.log("Router owner:", routerOwner);
        if (routerOwner != deployer) {
            console2.log("  (Router ownership set to provided multisig; acceptExecutor() must come from owner)");
        }
        console2.log("Router liquidator:", routerLiquidator);
        console2.log("Salt version:", saltVersion);
        console2.log("CREATE3 Factory:", CREATE3_FACTORY);
        console2.log("");

        result.deployed = new bool[](9);

        vm.startBroadcast();

        // Deploy ExecutionProxy (pure-VM executor, no constructor args per FR-11).
        bytes memory executionProxyCode = type(ExecutionProxy).creationCode;
        (result.executionProxy, result.deployed[0]) =
            deployIfNeeded(getExecutionProxySalt(), executionProxyCode, EXECUTION_PROXY);

        // Deploy Router with (owner, liquidator) constructor args. Router holds user approvals
        // and the entire fee / slippage model; ExecutionProxy is forwarded funds + commands on each call.
        bytes memory routerCode = abi.encodePacked(type(Router).creationCode, abi.encode(routerOwner, routerLiquidator));
        (result.router, result.routerDeployed) = deployIfNeeded(getSalt(ROUTER), routerCode, ROUTER);
        result.deployed[1] = result.routerDeployed;

        // Deploy stateless helpers (no constructor args)
        (result.tupler, result.deployed[2]) = deployIfNeeded(getSalt(TUPLER), type(Tupler).creationCode, TUPLER);

        (result.integer, result.deployed[3]) = deployIfNeeded(getSalt(INTEGER), type(Integer).creationCode, INTEGER);

        (result.bytes32Helper, result.deployed[4]) =
            deployIfNeeded(getSalt(BYTES32), type(Bytes32).creationCode, BYTES32);

        (result.blockchainInfo, result.deployed[5]) =
            deployIfNeeded(getSalt(BLOCKCHAIN_INFO), type(BlockchainInfo).creationCode, BLOCKCHAIN_INFO);

        (result.arraysConverter, result.deployed[6]) =
            deployIfNeeded(getSalt(ARRAYS_CONVERTER), type(ArraysConverter).creationCode, ARRAYS_CONVERTER);

        (result.mathHelpers, result.deployed[7]) =
            deployIfNeeded(getSalt(MATH_HELPERS), type(MathHelpers).creationCode, MATH_HELPERS);

        (result.signedMathHelpers, result.deployed[8]) =
            deployIfNeeded(getSalt(SIGNED_MATH_HELPERS), type(SignedMathHelpers).creationCode, SIGNED_MATH_HELPERS);

        // If the broadcasting account is also the Router owner, wire the pending executor in the
        // same broadcast. The owner multisig must still submit a follow-up `acceptExecutor()` tx
        // to activate the executor -- two-step transfer per FR-10.
        if (deployer == routerOwner) {
            Router(payable(result.router)).setPendingExecutor(result.executionProxy);
            console2.log("Router.setPendingExecutor called with ExecutionProxy:", result.executionProxy);
        } else {
            console2.log("");
            console2.log("[ACTION REQUIRED] Router owner must send two txs from the multisig:");
            console2.log("  1) router.setPendingExecutor(executionProxy)");
            console2.log("  2) router.acceptExecutor()");
        }

        vm.stopBroadcast();

        // Summary
        console2.log("");
        console2.log("=== Deployment Summary ===");
        console2.log("Router:        ", result.router);
        console2.log("ExecutionProxy:", result.executionProxy);
        uint256 newlyDeployed = 0;
        for (uint256 i = 0; i < 9; i++) {
            if (result.deployed[i]) newlyDeployed++;
        }
        console2.log("Newly deployed:", newlyDeployed);
        console2.log("Already deployed:", 9 - newlyDeployed);
        console2.log("Router owner:", routerOwner);
        console2.log("");
        console2.log("[REMINDER] acceptExecutor() must be invoked by the Router owner multisig");
        console2.log("           in a follow-up transaction before the Router can serve swaps.");

        return result;
    }

    /// @notice Preview deployment addresses without deploying
    function preview() public view {
        address deployer = msg.sender;
        address routerOwner = getRouterOwner();
        address routerLiquidator = getRouterLiquidator();
        string memory saltVersion = getSaltVersion();
        bool factoryAvailable = isDeployed(CREATE3_FACTORY);

        console2.log("=== Predicted Addresses ===");
        console2.log("Deployer:", deployer);
        console2.log("Router owner:", routerOwner);
        if (routerOwner != deployer) {
            console2.log("  (Router ownership will be set to provided multisig)");
        }
        console2.log("Router liquidator:", routerLiquidator);
        console2.log("Salt version:", saltVersion);
        console2.log("CREATE3 Factory:", CREATE3_FACTORY, factoryAvailable ? "(deployed)" : "(local-predict)");
        console2.log("");

        address execProxy = predictExecutionProxyAddress(deployer);
        console2.log("ExecutionProxy:", execProxy, isDeployed(execProxy) ? "(deployed)" : "(not deployed)");

        address router = predictAddress(deployer, ROUTER);
        console2.log("Router:", router, isDeployed(router) ? "(deployed)" : "(not deployed)");

        address tupler = predictAddress(deployer, TUPLER);
        console2.log("Tupler:", tupler, isDeployed(tupler) ? "(deployed)" : "(not deployed)");

        address integer = predictAddress(deployer, INTEGER);
        console2.log("Integer:", integer, isDeployed(integer) ? "(deployed)" : "(not deployed)");

        address bytes32Helper = predictAddress(deployer, BYTES32);
        console2.log("Bytes32:", bytes32Helper, isDeployed(bytes32Helper) ? "(deployed)" : "(not deployed)");

        address blockchainInfo = predictAddress(deployer, BLOCKCHAIN_INFO);
        console2.log("BlockchainInfo:", blockchainInfo, isDeployed(blockchainInfo) ? "(deployed)" : "(not deployed)");

        address arraysConverter = predictAddress(deployer, ARRAYS_CONVERTER);
        console2.log("ArraysConverter:", arraysConverter, isDeployed(arraysConverter) ? "(deployed)" : "(not deployed)");

        address mathHelpers = predictAddress(deployer, MATH_HELPERS);
        console2.log("MathHelpers:", mathHelpers, isDeployed(mathHelpers) ? "(deployed)" : "(not deployed)");

        address signedMathHelpers = predictAddress(deployer, SIGNED_MATH_HELPERS);
        console2.log(
            "SignedMathHelpers:", signedMathHelpers, isDeployed(signedMathHelpers) ? "(deployed)" : "(not deployed)"
        );
    }
}
