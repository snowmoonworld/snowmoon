// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {PonsV2BondingCurve} from "../src/v2/PonsV2BondingCurve.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/** Sell all remaining SMOKE. TOKEN, CURVE, DEPLOYER_PK env required. */
contract SellRest is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PK");
        address deployer = vm.addr(pk);
        address token = vm.envAddress("TOKEN");
        PonsV2BondingCurve curve = PonsV2BondingCurve(payable(vm.envAddress("CURVE")));

        uint256 bal = IERC20(token).balanceOf(deployer);
        console.log("SMOKE balance:", bal);
        require(bal > 0, "nothing to sell");

        vm.startBroadcast(pk);
        IERC20(token).approve(address(curve), bal);
        uint256 back = curve.sell(bal, 0, deployer);
        console.log("sold for ETH:", back);
        vm.stopBroadcast();
    }
}
