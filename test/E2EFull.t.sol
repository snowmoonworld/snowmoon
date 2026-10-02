// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {GraduationPhase} from "../src/v2/interfaces/ILaunchpadV2.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";

/**
 * Full E2E against a pre-deployed stack (see DeployMemeLaunch.s.sol).
 * Env: FACTORY = deployed PonsV2LaunchFactory on the fork.
 */
contract E2EFullTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);

    PonsV2LaunchFactory factory;

    function setUp() public {
        factory = PonsV2LaunchFactory(payable(vm.envAddress("FACTORY")));
    }

    function test_launch_buy_sell_graduate() public {
        address trader = address(0x1234);
        vm.deal(trader, 100 ether);

        // --- launch (native ETH quote) ---
        vm.startPrank(trader);
        PonsV2LauncherToken.Socials memory socials = PonsV2LauncherToken.Socials("", "", "", "", "");
        PonsV2LaunchFactory.TokenParams memory p = PonsV2LaunchFactory.TokenParams({
            name: "Meme Launch Test",
            symbol: "MLT",
            logo: "ipfs://test",
            description: "e2e",
            socials: socials,
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            buybackEnabled: false,
            salt: bytes32(uint256(7)),
            expectedEconomics: bytes32(0)
        });
        (address token, address curve) = factory.launchToken{value: 0.0005 ether}(p, 0, address(0));
        vm.stopPrank();
        assertTrue(token != address(0) && curve != address(0), "launch failed");

        // snipe tax: deployer exempt, stranger taxed in the launch second
        assertEq(PonsV2BondingCurve(curve).snipeTaxBpsFor(trader), 0, "deployer exempt");
        assertGt(PonsV2BondingCurve(curve).snipeTaxBpsFor(address(0x9999)), 9000, "stranger taxed");

        // --- buy & sell on the curve ---
        vm.startPrank(trader);
        uint256 out = PonsV2BondingCurve(curve).buy{value: 1 ether}(1 ether, 0, trader);
        assertGt(out, 0, "buy failed");
        IERC20(token).approve(curve, out / 2);
        uint256 back = PonsV2BondingCurve(curve).sell(out / 2, 0, trader);
        assertGt(back, 0, "sell failed");
        vm.stopPrank();

        // --- drive to graduation ---
        vm.startPrank(trader);
        uint256 tries = 0;
        while (PonsV2BondingCurve(curve).sellableTokens() > 0 && tries < 20) {
            PonsV2BondingCurve(curve).buy{value: 1 ether}(1 ether, 0, trader);
            tries++;
        }
        vm.stopPrank();
        assertEq(PonsV2BondingCurve(curve).sellableTokens(), 0, "curve sold out");

        GraduationPhase phase = factory.getLaunchedToken(token).phase;
        console.log("phase after sellout:", uint256(phase));
        if (phase == GraduationPhase.Swept) {
            factory.createGraduatedPool(token);
            phase = factory.getLaunchedToken(token).phase;
        }
        assertEq(uint256(phase), uint256(GraduationPhase.PoolCreated), "graduated");

        // --- V4 pool live behind the hook ---
        address hook = address(factory.memeHook());
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(token),
            fee: 0,
            tickSpacing: 200,
            hooks: IHooks(hook)
        });
        (uint160 sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(key.toId());
        assertGt(sqrtPriceX96, 0, "v4 pool initialized");
        console.log("V4 pool live");
    }
}
