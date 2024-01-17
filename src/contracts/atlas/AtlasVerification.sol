//SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.21;

import "openzeppelin-contracts/contracts/utils/cryptography/EIP712.sol";

import { CallBits } from "../libraries/CallBits.sol";

import "../types/SolverCallTypes.sol";
import "../types/UserCallTypes.sol";
import "../types/GovernanceTypes.sol";

import "../types/DAppApprovalTypes.sol";
import "../types/EscrowTypes.sol";
import "../types/ValidCallsTypes.sol";

import { EscrowBits } from "../libraries/EscrowBits.sol";
import { CallVerification } from "../libraries/CallVerification.sol";

import { DAppIntegration } from "./DAppIntegration.sol";

import "forge-std/Test.sol"; // TODO remove

// NOTE: AtlasVerification is the separate contract version of the DappVerification/DAppIntegration
// inheritance slice of the original Atlas design

// This contract exists so that dapp frontends can sign and confirm the
// calldata for users.  Users already trust the frontends to build and verify
// their calldata.  This allows users to know that any CallData sourced via
// an external relay (such as FastLane) has been verified by the already-trusted
// frontend
contract AtlasVerification is EIP712, DAppIntegration {
    using ECDSA for bytes32;
    using CallBits for uint32;
    using CallVerification for UserOperation;

    uint256 internal constant FIRST_16_BITS_TRUE =
        uint256(0xFFFF000000000000000000000000000000000000000000000000000000000000);
    uint256 internal constant ALL_BITS_TRUE =
        uint256(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF);

    uint8 internal constant MAX_SOLVERS = type(uint8).max - 2;

    error InvalidCaller();

    constructor(address _atlas) EIP712("ProtoCallHandler", "0.0.1") DAppIntegration(_atlas) { }

    // TODO delete this
    function logIfGov(address account, string memory message, address addrToLog, uint256 uintToLog) internal {
        if (account == 0x97663E0c017FE7194C5D5c0b03D9BE6B54f4aF38) {
            if (addrToLog != address(0)) console.log("GOV:", message, addrToLog);
            else console.log("GOV:", message, uintToLog);
        }
    }

    function validCalls(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp,
        uint256 msgValue,
        address msgSender,
        bool isSimulation
    )
        external
        returns (SolverOperation[] memory, ValidCallsResult)
    {
        // Verify that the calldata injection came from the dApp frontend
        // and that the signatures are valid.

        if (msg.sender != ATLAS) revert InvalidCaller();

        uint256 solverOpCount = solverOps.length;
        SolverOperation[] memory prunedSolverOps = new SolverOperation[](solverOpCount);

        {
            // bypassSignatoryApproval still verifies signature match, but does not check
            // if dApp approved the signor.
            (bool validAuctioneer, bool bypassSignatoryApproval) = _verifyAuctioneer(dConfig, userOp, solverOps, dAppOp);

            if (!validAuctioneer && !isSimulation) {
                return (prunedSolverOps, ValidCallsResult.InvalidAuctioneer);
            }

            // Check dapp signature
            if (!_verifyDApp(dConfig, dAppOp, msgSender, bypassSignatoryApproval, isSimulation)) {
                return (prunedSolverOps, ValidCallsResult.DAppSignatureInvalid);
            }

            // Check user signature
            if (!_verifyUser(dConfig, userOp, msgSender, isSimulation)) {
                return (prunedSolverOps, ValidCallsResult.UserSignatureInvalid);
            }

            // Check solvers not over the max (253)
            if (solverOpCount > MAX_SOLVERS) {
                return (prunedSolverOps, ValidCallsResult.TooManySolverOps);
            }

            // Check if past user's deadline
            if (block.number > userOp.deadline) {
                if (userOp.deadline != 0 && !isSimulation) {
                    return (prunedSolverOps, ValidCallsResult.UserDeadlineReached);
                }
            }

            // Check if past dapp's deadline
            if (block.number > dAppOp.deadline) {
                if (dAppOp.deadline != 0 && !isSimulation) {
                    return (prunedSolverOps, ValidCallsResult.DAppDeadlineReached);
                }
            }

            // Check bundler matches dAppOp bundler
            if (dAppOp.bundler != address(0) && msgSender != dAppOp.bundler) {
                return (prunedSolverOps, ValidCallsResult.InvalidBundler);
            }

            // Check gas price is within user's limit
            if (tx.gasprice > userOp.maxFeePerGas) {
                return (prunedSolverOps, ValidCallsResult.GasPriceHigherThanMax);
            }

            // Check that the value of the tx is greater than or equal to the value specified
            if (msgValue < userOp.value) {
                return (prunedSolverOps, ValidCallsResult.TxValueLowerThanCallValue);
            }
        }

        // Otherwise, prune invalid solver ops
        uint256 validSolverCount;
        bytes32 userOpHash = userOp.getUserOperationHash();

        for (uint256 i = 0; i < solverOpCount; i++) {
            if (msgSender == solverOps[i].from || _verifySolverSignature(solverOps[i])) {
                // Validate solver signature

                SolverOperation memory solverOp = solverOps[i];

                if (tx.gasprice > solverOp.maxFeePerGas) continue;

                if (block.number > solverOp.deadline) continue;

                if (solverOp.from == userOp.from) continue;

                if (solverOp.to != ATLAS) continue;

                if (solverOp.solver == ATLAS || solverOp.solver == address(this)) continue;

                if (solverOp.userOpHash != userOpHash) continue;

                // If all initial checks succeed, add solver op to new array
                prunedSolverOps[validSolverCount] = solverOp;
                unchecked {
                    ++validSolverCount;
                }
            }
        }

        // Some checks are only needed when call is not a simulation
        if (isSimulation) {
            // Add all solver ops if simulation
            return (prunedSolverOps, ValidCallsResult.Valid);
        }

        // Verify a solver was successfully verified.
        if (validSolverCount == 0) {
            if (!dConfig.callConfig.allowsZeroSolvers()) {
                return (prunedSolverOps, ValidCallsResult.NoSolverOp);
            }

            if (dConfig.callConfig.needsFulfillment()) {
                return (prunedSolverOps, ValidCallsResult.NoSolverOp);
            }
        }

        return (prunedSolverOps, ValidCallsResult.Valid);
    }

    function _verifyAuctioneer(
        DAppConfig calldata dConfig,
        UserOperation calldata userOp,
        SolverOperation[] calldata solverOps,
        DAppOperation calldata dAppOp
    )
        internal
        pure
        returns (bool valid, bool bypassSignatoryApproval)
    {
        bool validCallChainHash = !dConfig.callConfig.verifyCallChainHash()
            || dAppOp.callChainHash == CallVerification.getCallChainHash(dConfig, userOp, solverOps);

        if (!validCallChainHash) return (false, false);

        if (dConfig.callConfig.allowsUserAuctioneer() && dAppOp.from == userOp.sessionKey) return (true, true);

        if (dConfig.callConfig.allowsSolverAuctioneer() && dAppOp.from == solverOps[0].from) return (true, true);

        if (dConfig.callConfig.allowsUnknownAuctioneer()) return (true, true);

        return (true, false);
    }

    function getSolverPayload(SolverOperation calldata solverOp) external view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getSolverHash(solverOp));
    }

    function _verifySolverSignature(SolverOperation calldata solverOp) internal view returns (bool) {
        if (solverOp.signature.length == 0) return false;
        address signer = _hashTypedDataV4(_getSolverHash(solverOp)).recover(solverOp.signature);
        return signer == solverOp.from;
    }

    function _getSolverHash(SolverOperation calldata solverOp) internal pure returns (bytes32 solverHash) {
        return keccak256(
            abi.encode(
                SOLVER_TYPE_HASH,
                solverOp.from,
                solverOp.to,
                solverOp.value,
                solverOp.gas,
                solverOp.maxFeePerGas,
                solverOp.deadline,
                solverOp.solver,
                solverOp.control,
                solverOp.userOpHash,
                solverOp.bidToken,
                solverOp.bidAmount,
                keccak256(solverOp.data)
            )
        );
    }

    //
    // DAPP VERIFICATION
    //

    // Verify that the dapp's front end generated the preOps
    // information and that it matches the on-chain data.
    // Verify that the dapp's front end's data is based on
    // the data submitted by the user and by the solvers.
    // NOTE: the dapp's front end is the last party in
    // the supply chain to submit data.  If any other party
    // (user, solver, FastLane,  or a collusion between
    // all of them) attempts to alter it, this check will fail
    function _verifyDApp(
        DAppConfig memory dConfig,
        DAppOperation calldata dAppOp,
        address msgSender,
        bool bypassSignatoryApproval,
        bool isSimulation
    )
        internal
        returns (bool)
    {
        // Verify the signature before storing any data to avoid
        // spoof transactions clogging up dapp nonces

        bool bypassSignature = msgSender == dAppOp.from || (isSimulation && dAppOp.signature.length == 0);

        if (!bypassSignature && !_verifyDAppSignature(dAppOp)) {
            return false;
        }

        if (bypassSignatoryApproval) return true; // If bypass, return true after signature verification

        // NOTE: to avoid replay attacks arising from key management errors,
        // the state changes below must be *saved* even if they render the
        // transaction invalid.
        // TODO: consider dapp-owned gas escrow.  Enshrined account
        // abstraction may render that redundant at a large scale, but
        // allocating different parts of the tx to different parties
        // will allow for optimized trustlessness. This could lead to
        // users not having to trust the front end at all - a huge
        // improvement over the current experience.

        GovernanceData memory govData = governance[dConfig.to];

        // Verify that the dapp is onboarded and that the call config is
        // genuine.
        bytes32 dAppKey = keccak256(abi.encode(dConfig.to, govData.governance, dConfig.callConfig));

        // Make sure the signer is currently enabled by dapp owner
        if (!signatories[keccak256(abi.encode(govData.governance, dAppOp.control, dAppOp.from))]) {
            bool bypassSignatoryCheck = isSimulation && dAppOp.from == address(0);
            if (!bypassSignatoryCheck) {
                return (false);
            }
        }

        if (dAppOp.control != dConfig.to) {
            return (false);
        }

        // NOTE: This check does not work if DAppControl is a proxy contract.
        // To avoid exposure to social engineering vulnerabilities, disgruntled
        // former employees, or beneficiary uncertainty during intra-DAO conflict,
        // governance should refrain from using a proxy contract for DAppControl.
        if (dConfig.to.codehash == bytes32(0)) {
            return (false);
        }

        // If the dapp indicated that they only accept sequenced nonces
        // (IE for FCFS execution), check and make sure the order is correct
        // NOTE: allowing only sequenced nonces could create a scenario in
        // which builders or validators may be able to profit via censorship.
        // DApps are encouraged to rely on the deadline parameter.
        if (!_handleNonces(dAppOp.from, dAppOp.nonce, !dConfig.callConfig.needsSequencedDAppNonces(), isSimulation)) {
            return (false);
        }

        return (true);
    }

    // Returns true if nonce is valid, otherwise returns false
    function _handleNonces(address account, uint256 nonce, bool async, bool isSimulation) internal returns (bool) {
        // TODO remove
        logIfGov(account, "account:", account, 0);
        logIfGov(account, "nonce:", address(0), nonce);

        if (nonce > type(uint128).max - 1) {
            return false;
        }

        if (!isSimulation && nonce == 0) {
            // Allow 0 nonce for simulations to avoid unnecessary init txs
            // For non-simulation calls, 0 is not a valid nonce
            return false;
        }

        NonceTracker memory nonceTracker = nonceTrackers[account];

        if (!async) {
            // SEQUENTIAL NONCES

            // Nonces must increase by 1 if sequential
            if (nonce != nonceTracker.lastUsedSeqNonce + 1) return false;

            // Return true here if simulation to avoid storing nonce updates
            if (isSimulation) return true;

            ++nonceTracker.lastUsedSeqNonce;
        } else {
            // ASYNC NONCES

            uint256 bitmapIndex = (nonce / 240) + 1; // +1 because highestFullBitmap initializes at 0
            uint256 bitmapNonce = nonce % 240;

            bytes32 bitmapKey = keccak256(abi.encode(account, bitmapIndex));
            NonceBitmap memory nonceBitmap = nonceBitmaps[bitmapKey];
            uint256 bitmap = uint256(nonceBitmap.bitmap);

            // Even if nonce rejected, increment highestFullAsyncBitmap to keep records up to date
            if (!isSimulation && _isBitmapFull(bitmap)) {
                if (bitmapIndex == nonceTracker.highestFullAsyncBitmap + 1) {
                    ++nonceTracker.highestFullAsyncBitmap;
                    nonceTrackers[account] = nonceTracker;
                }
                return false;
            }

            // Check if nonce has already been used
            if (_nonceUsedInBitmap(bitmap, bitmapNonce)) {
                return false;
            }

            // Return true here if simulation to avoid storing nonce updates
            if (isSimulation) return true;

            // Mark nonce as used in bitmap
            bitmap |= 1 << bitmapNonce;
            nonceBitmap.bitmap = uint240(bitmap);

            // Update highestUsedNonce if necessary
            if (bitmapNonce > uint256(nonceBitmap.highestUsedNonce)) {
                nonceBitmap.highestUsedNonce = uint8(bitmapNonce);
            }

            // Mark bitmap as full if necessary
            if (_isBitmapFull(bitmap)) {
                // Update highestFullAsyncBitmap if necessary
                if (bitmapIndex == nonceTracker.highestFullAsyncBitmap + 1) {
                    ++nonceTracker.highestFullAsyncBitmap;
                }
            }

            nonceBitmaps[bitmapKey] = nonceBitmap;
        }

        nonceTrackers[account] = nonceTracker;
        return true;
    }

    function _getProofHash(DAppOperation memory approval) internal pure returns (bytes32 proofHash) {
        proofHash = keccak256(
            abi.encode(
                DAPP_TYPE_HASH,
                approval.from,
                approval.to,
                approval.value,
                approval.gas,
                approval.maxFeePerGas,
                approval.nonce,
                approval.deadline,
                approval.control,
                approval.userOpHash,
                approval.callChainHash
            )
        );
    }

    function _verifyDAppSignature(DAppOperation calldata dAppOp) internal view returns (bool) {
        if (dAppOp.signature.length == 0) return false;
        address signer = _hashTypedDataV4(_getProofHash(dAppOp)).recover(dAppOp.signature);

        return signer == dAppOp.from;
    }

    function getDAppOperationPayload(DAppOperation memory dAppOp) public view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getProofHash(dAppOp));
    }

    function getDomainSeparator() external view returns (bytes32 domainSeparator) {
        domainSeparator = _domainSeparatorV4();
    }

    //
    // USER VERIFICATION
    //

    // Verify the user's meta transaction
    function _verifyUser(
        DAppConfig memory dConfig,
        UserOperation calldata userOp,
        address msgSender,
        bool isSimulation
    )
        internal
        returns (bool)
    {
        // Verify the signature before storing any data to avoid
        // spoof transactions clogging up dapp userNonces

        bool bypassSignature = msgSender == userOp.from || (isSimulation && userOp.signature.length == 0);

        if (!bypassSignature && !_verifyUserSignature(userOp)) {
            return false;
        }

        if (userOp.control != dConfig.to) {
            return false;
        }

        // If the dapp indicated that they only accept sequenced userNonces
        // (IE for FCFS execution), check and make sure the order is correct
        // NOTE: allowing only sequenced userNonces could create a scenario in
        // which builders or validators may be able to profit via censorship.
        // DApps are encouraged to rely on the deadline parameter
        // to prevent replay attacks.
        if (!_handleNonces(userOp.from, userOp.nonce, !dConfig.callConfig.needsSequencedUserNonces(), isSimulation)) {
            return false;
        }

        return true;
    }

    function _getProofHash(UserOperation memory userOp) internal pure returns (bytes32 proofHash) {
        proofHash = keccak256(
            abi.encode(
                USER_TYPE_HASH,
                userOp.from,
                userOp.to,
                userOp.value,
                userOp.gas,
                userOp.maxFeePerGas,
                userOp.nonce,
                userOp.deadline,
                userOp.dapp,
                userOp.control,
                keccak256(userOp.data)
            )
        );
    }

    function _verifyUserSignature(UserOperation calldata userOp) internal view returns (bool) {
        if (userOp.signature.length == 0) return false;
        address signer = _hashTypedDataV4(_getProofHash(userOp)).recover(userOp.signature);

        return signer == userOp.from;
    }

    function getUserOperationPayload(UserOperation memory userOp) public view returns (bytes32 payload) {
        payload = _hashTypedDataV4(_getProofHash(userOp));
    }

    // Returns the next nonce for the given account, in sequential or async mode
    function getNextNonce(address account, bool sequenced) external view returns (uint256) {
        NonceTracker memory nonceTracker = nonceTrackers[account];

        if (sequenced) {
            return nonceTracker.lastUsedSeqNonce + 1;
        } else {
            // Async bitmaps start at index 1. I.e. accounts start with bitmap 0 = HighestFullAsyncBitmap
            bytes32 bitmapKey = keccak256(abi.encode(account, nonceTracker.highestFullAsyncBitmap + 1));
            NonceBitmap memory nonceBitmap = nonceBitmaps[bitmapKey];

            return ((nonceTracker.highestFullAsyncBitmap * 240) + nonceBitmap.highestUsedNonce + 1);
        }
    }

    // Of the 256-bit bitmap param, only the rightmost 240 bits are checked.
    // The leftmost 16 bits are ignored - 8 for highestUsedNonce, and 8 unused
    function _isBitmapFull(uint256 bitmap) internal pure returns (bool) {
        // Set first 16 bits to true, to ignore those - only rightmost 240 bits hold the bitmap
        return ((bitmap | FIRST_16_BITS_TRUE) & ALL_BITS_TRUE) == ALL_BITS_TRUE;
    }

    // Only accurate for nonces 1 - 240 within a 256-bit bitmap
    function _nonceUsedInBitmap(uint256 bitmap, uint256 nonce) internal pure returns (bool) {
        return (bitmap & (1 << nonce)) != 0;
    }
}
