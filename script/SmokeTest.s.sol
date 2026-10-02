// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {PonsV2LauncherToken} from "../src/v2/PonsV2LauncherToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * Mainnet smoke test: launch -> buy -> sell.
 *   FACTORY, DEPLOYER_PK env required.
 */
contract SmokeTest is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(vm.envAddress("FACTORY")));

        vm.startBroadcast(pk);

        PonsV2LauncherToken.Socials memory socials =
            PonsV2LauncherToken.Socials("https://x.com/", "", "", "https://beta.ml.fun", "");
        PonsV2LaunchFactory.TokenParams memory p = PonsV2LaunchFactory.TokenParams({
            name: "Smoke Test",
            symbol: "SMOKE",
            logo: "",
            description: "Meme Launch deployment smoke test.",
            socials: socials,
            creatorFeeRecipient: address(0),
            creatorTaxBps: 0,
            buybackEnabled: false,
            salt: keccak256(abi.encodePacked(block.timestamp, deployer)),
            expectedEconomics: bytes32(0)
        });
        (address token, address curve) = factory.launchToken{value: 0.0005 ether}(p, 0, address(0));
        console.log("token:", token);
        console.log("curve:", curve);

        // buy 0.002 ETH (deployer is snipe-exempt)
        uint256 buyIn = 0.002 ether;
        uint256 out = PonsV2BondingCurve(curve).buy{value: buyIn}(buyIn, 0, deployer);
        console.log("bought tokens:", out);

        // sell half back
        uint256 sellAmt = out / 2;
        IERC20(token).approve(curve, sellAmt);
        uint256 back = PonsV2BondingCurve(curve).sell(sellAmt, 0, deployer);
        console.log("sold for ETH:", back);

        vm.stopBroadcast();
    }
}
