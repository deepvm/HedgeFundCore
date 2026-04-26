// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {Script, console} from "forge-std/Script.sol";
import {HedgeFund} from "../src/HedgeFund.sol";

contract DeployHedgeFund is Script {
    function run() external {
        address owner = vm.envAddress("HEDGE_FUND_OWNER");
        address asset = vm.envAddress("HEDGE_FUND_ASSET");

        string memory shareName = vm.envString("HEDGE_FUND_SHARE_NAME");
        string memory shareSymbol = vm.envString("HEDGE_FUND_SHARE_SYMBOL");

        vm.startBroadcast();
        HedgeFund fund = new HedgeFund(owner, asset, shareName, shareSymbol);
        vm.stopBroadcast();

        console.log("HedgeFund deployed", address(fund));
    }
}
