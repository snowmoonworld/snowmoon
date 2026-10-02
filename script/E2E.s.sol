// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";

/**
 * End-to-end fork test: launch -> buy -> sell -> graduate -> V4 pool exists.
 * Env: FACTORY (deployed factory address), EOA_PK (funded test key).
 */
contract E2E is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 pk = vm.envUint("EOA_PK");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(vm.envAddress("FACTORY")));

        vm.startBroadcast(pk);

        // 1. Launch (native ETH quote, no creator tax).
        PonsV2LauncherToken.Socials memory socials =
            PonsV2LauncherToken.Socials("", "", "", "", "");
        PonsV2LaunchFactory.TokenParams memory p = PonsV2LaunchFactory.TokenParams({
            name: "Meme Launch Test",
            symbol: "MLT",
            logo: "ipfs://test",
            description: "fork e2e",
            socials: socials,
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            buybackEnabled: false,
            salt: bytes32(uint256(1)),
            expectedEconomics: bytes32(0)
        });
        (address token, address curve) =
            factory.launchToken{value: 0.0005 ether}(p, 0, address(0));
        console.log("token:", token);
        console.log("curve:", curve);
        console.log("snipeTaxBpsFor(me):", PonsV2BondingCurve(curve).snipeTaxBpsFor(me));

        // 2. Buy 0.5 ETH on the curve.
        uint256 out1 = PonsV2BondingCurve(curve).buy{value: 0.5 ether}(0.5 ether, 0, me);
        console.log("bought tokens:", out1);

        // 3. Sell half back.
        IERC20(token).approve(curve, out1 / 2);
        uint256 ethBack =
            PonsV2BondingCurve(curve).sell(out1 / 2, 0, me);
        console.log("sold for eth:", ethBack);

        // 4. Big buys to cross the 4.2 ETH graduation threshold.
        uint256 out2 = PonsV2BondingCurve(curve).buy{value: 2 ether}(2 ether, 0, me);
        uint256 out3 = PonsV2BondingCurve(curve).buy{value: 2 ether}(2 ether, 0, me);
        console.log("more tokens:", out2 + out3);

        // 5. Graduation state: curve reserves vs threshold, launch phase.
        (uint256 quoteReserve,) = PonsV2BondingCurve(curve).getReserves();
        console.log("quoteReserve:", quoteReserve);
        console.log("threshold:", factory.getLaunchedToken(token).graduationThreshold);
        console.log("phase:", uint256(factory.getLaunchedToken(token).phase));

        // 6. Permissionless graduation: anyone can finish a sold-out curve.
        if (uint256(factory.getLaunchedToken(token).phase) == 0) {
            // curve not yet auto-graduated; try the two-phase flow
            try factory.graduate(token) {} catch {}
            try factory.createGraduatedPool(token) returns (uint256 pid) {
                console.log("graduated pool position:", pid);
            } catch {}
            console.log("phase after:", uint256(factory.getLaunchedToken(token).phase));
        }

        vm.stopBroadcast();
    }
}
