// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.25;

import "forge-std/Script.sol";

import { DeployBaseScript } from "script/base/deploy-base.s.sol";

import { Atlas } from "src/contracts/atlas/Atlas.sol";

/// @dev npm run transfer-surcharge-recipient:sepolia -- <recipient_address_or_private_key>
/// @dev If input is a 20-byte address, only transfers the recipient role
/// @dev If input is a 32-byte private key, transfers and accepts the role
contract TransferSurchargeRecipientScript is DeployBaseScript {
    function run(string calldata _new_recipient) external {
        console.log("\n=== Transferring Atlas Surcharge Recipient ===\n");

        // Determine if input is an address or a private key ('0x' + 40 or 64 chars).
        bool isAddress = bytes(_new_recipient).length == 42;
        bool isPrivateKey = bytes(_new_recipient).length == 66;

        address newRecipient;
        uint256 recipientPrivateKey;

        if (isAddress) {
            newRecipient = vm.parseAddress(_new_recipient);
            console.log("Input type: \t\t\t\t Address (will only transfer recipient role)");
        } else if (isPrivateKey) {
            recipientPrivateKey = vm.parseUint(_new_recipient);
            newRecipient = vm.addr(recipientPrivateKey);
            console.log("Input type: \t\t\t\t Private key (will transfer and accept recipient role)");
        } else {
            revert("Input must be a 20-byte address or 32-byte private key");
        }

        // Get the deployer's private key from environment.
        uint256 deployerPrivateKey = vm.envUint("GOV_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Get Atlas contract address from deployments.
        address atlasAddress = _getAddressFromDeploymentsJson(".ATLAS");
        Atlas atlas = Atlas(payable(atlasAddress));

        console.log("Deployer address: \t\t\t", deployer);
        console.log("Atlas address: \t\t\t", atlasAddress);
        console.log("New surcharge recipient: \t\t", newRecipient);

        // Transfer the surcharge recipient role to the new address.
        vm.broadcast(deployerPrivateKey);
        atlas.transferSurchargeRecipient(newRecipient);

        if (isPrivateKey) {
            vm.broadcast(recipientPrivateKey);
            atlas.becomeSurchargeRecipient();
        }
    }
}
