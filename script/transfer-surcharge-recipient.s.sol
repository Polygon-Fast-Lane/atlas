// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "forge-std/Script.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { Atlas } from "src/contracts/atlas/Atlas.sol";

/// @dev npm run transfer-surcharge-recipient:sepolia -- <address>
contract TransferSurchargeRecipientScript is DeployBaseScript {
    function run(string calldata _newRecipient) external {
        console.log("\n=== Transferring Atlas Surcharge Recipient ===\n");

        // Hex string to address.
        address newRecipient = vm.parseAddress(_newRecipient);

        // Get the deployer's private key from environment.
        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get Atlas contract address from deployments.
        address atlasAddress = _getAddressFromDeploymentsJson(".ATLAS");
        Atlas atlas = Atlas(payable(atlasAddress));

        console.log("Deployer address: \t\t\t", deployer);
        console.log("Atlas address: \t\t\t\t", atlasAddress);
        console.log("New surcharge recipient: \t\t\t", newRecipient);

        // Transfer the surcharge recipient role to the new address.
        vm.startBroadcast(deployerPrivateKey);
        atlas.transferSurchargeRecipient(newRecipient);
        vm.stopBroadcast();

        console.log("\nSurcharge recipient successfully transferred to:", newRecipient);
    }
}
