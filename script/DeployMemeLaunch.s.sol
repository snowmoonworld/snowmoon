// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPonsV2FeeEscrow} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PonsV2FeeEscrow} from "../src/v2/PonsV2FeeEscrow.sol";
import {PonsV2LaunchLocker} from "../src/v2/PonsV2LaunchLocker.sol";
import {PonsV2MemeHook} from "../src/v2/hooks/PonsV2MemeHook.sol";
import {PonsV2BuybackVault} from "../src/v2/PonsV2BuybackVault.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2GraduationExecutor} from "../src/v2/PonsV2GraduationExecutor.sol";
import {PonsV2LaunchDeployer} from "../src/v2/PonsV2LaunchDeployer.sol";

/**
 * @title DeployMemeLaunch
 * @notice Deploys the full Meme Launch v2 stack on Ethereum mainnet and
 * wires it into a live launchpad. Economics mirror pons v2's live config.
 *
 * Env:
 *   DEPLOYER_PK        private key of the funded deployer (0x-prefixed)
 *   PROTOCOL_FEE_WALLET  fee recipient (launch fees + protocol fee share)
 *
 * Mainnet canonical deps (verified onchain):
 *   PoolManager     0x000000000004444c5dc75cB358380D2e3dE08A90
 *   PositionManager 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e
 *   Permit2         0x000000000022D473030F116dDEE9F6B43aC78BA3
 */
contract DeployMemeLaunch is Script {
    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IPositionManager constant POSITION_MANAGER =
        IPositionManager(0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e);
    IAllowanceTransfer constant PERMIT2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    // beforeInitialize | afterSwap | afterSwapReturnDelta
    uint160 constant HOOK_FLAGS = uint160((1 << 13) | (1 << 6) | (1 << 2));
    // Forge scripts route `new {salt:}` through this CREATE2 deployer.
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PK");
        address protocolFeeWallet = vm.envAddress("PROTOCOL_FEE_WALLET");
        address owner = vm.addr(deployerPk);
        require(protocolFeeWallet != address(0), "PROTOCOL_FEE_WALLET");

        vm.startBroadcast(deployerPk);

        // 1. Fee escrow (new implementation; upstream repo had only the interface).
        PonsV2FeeEscrow escrow = new PonsV2FeeEscrow(owner);
        console.log("PonsV2FeeEscrow:", address(escrow));

        // 2. Permanent V4 position locker.
        PonsV2LaunchLocker locker = new PonsV2LaunchLocker(owner, address(POSITION_MANAGER));
        console.log("PonsV2LaunchLocker:", address(locker));

        // 3. Meme hook at a mined address carrying the required permission flags.
        bytes memory hookInitCode = abi.encodePacked(
            type(PonsV2MemeHook).creationCode,
            abi.encode(POOL_MANAGER, IPonsV2FeeEscrow(address(escrow)), protocolFeeWallet, owner)
        );
        bytes32 salt = _mineHookSalt(CREATE2_DEPLOYER, keccak256(hookInitCode));
        PonsV2MemeHook hook = new PonsV2MemeHook{salt: salt}(
            POOL_MANAGER, IPonsV2FeeEscrow(address(escrow)), protocolFeeWallet, owner
        );
        console.log("PonsV2MemeHook:", address(hook));

        // 4. Buyback vault (5-year vesting).
        PonsV2BuybackVault vault = new PonsV2BuybackVault(owner, hook, IPonsV2FeeEscrow(address(escrow)));
        console.log("PonsV2BuybackVault:", address(vault));

        // 5. Factory.
        PonsV2LaunchFactory factory = new PonsV2LaunchFactory(
            owner,
            POOL_MANAGER,
            POSITION_MANAGER,
            PERMIT2,
            locker,
            hook,
            IPonsV2FeeEscrow(address(escrow)),
            vault,
            0.0005 ether // launch fee, mirrors pons v2
        );
        console.log("PonsV2LaunchFactory:", address(factory));

        // 6. Graduation executor + launch deployer helpers.
        PonsV2GraduationExecutor executor =
            new PonsV2GraduationExecutor(POSITION_MANAGER, PERMIT2, locker, address(factory));
        console.log("PonsV2GraduationExecutor:", address(executor));
        PonsV2LaunchDeployer deployer = new PonsV2LaunchDeployer(address(factory));
        console.log("PonsV2LaunchDeployer:", address(deployer));

        // 7. Wire everything together.
        locker.setFactory(address(factory));
        vault.setFactory(address(factory));
        hook.setFactory(address(factory));
        hook.setBuybackVault(vault);
        factory.setGraduationExecutor(executor);
        factory.setLaunchDeployer(deployer);

        // 8. Live config, mirrored from pons v2.
        factory.addLaunchConfig(
            PonsV2LaunchFactory.LaunchConfig({
                supply: 1_000_000_000 * 1e18,
                curveFeeBps: 100, // 1%
                phantomQuote: 1.68 ether,
                graduationThreshold: 4.2 ether,
                poolFee: 0, // v4 pool charges 0%; the hook charges the fee
                tickSpacing: 200,
                enabled: true
            })
        );
        factory.setSnipeTaxStartBps(9_900); // 99%
        factory.setSnipeTaxSeconds(3);
        factory.setLaunchEnabled(true); // public launches

        vm.stopBroadcast();

        console.log("---- Meme Launch deployed ----");
        console.log("owner:", owner);
        console.log("protocolFeeWallet:", protocolFeeWallet);
    }

    /**
     * @notice Mines a CREATE2 salt so the hook deploys to an address whose
     * low 14 bits exactly equal HOOK_FLAGS (beforeInitialize | afterSwap |
     * afterSwapReturnDelta), as Uniswap V4 requires. `deployer` must be the
     * EOA that broadcasts the deployment.
     */
    function _mineHookSalt(address deployer, bytes32 initCodeHash) internal pure returns (bytes32) {
        for (uint256 i = 0;; ++i) {
            bytes32 salt = bytes32(i);
            address addr = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash))))
            );
            if (uint160(addr) & 0x3FFF == HOOK_FLAGS) return salt;
        }
    }
}
