// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {PonsV2LaunchFactory} from "../src/v2/PonsV2LaunchFactory.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";

/** Finish buying out the curve to trigger graduation, then verify the V4 pool. */
contract E2E2 is Script {
    function run() external {
        uint256 pk = vm.envUint("EOA_PK");
        address me = vm.addr(pk);
        PonsV2LaunchFactory factory = PonsV2LaunchFactory(payable(vm.envAddress("FACTORY")));
        address token = vm.envAddress("TOKEN");
        address curve = factory.getLaunchedToken(token).curve;

        vm.startBroadcast(pk);
        console.log("sellable before:", PonsV2BondingCurve(curve).sellableTokens());
        // Buy enough to exhaust the curve; excess is refunded in the same tx.
        uint256 out = PonsV2BondingCurve(curve).buy{value: 3 ether}(3 ether, 0, me);
        console.log("bought:", out);
        console.log("phase:", uint256(factory.getLaunchedToken(token).phase));
        console.log("sellable after:", PonsV2BondingCurve(curve).sellableTokens());
        vm.stopBroadcast();
    }
}
