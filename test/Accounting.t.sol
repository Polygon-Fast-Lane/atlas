// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import "forge-std/Test.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";

import {BaseTest} from "./base/BaseTest.t.sol";
import {TxBuilder} from "../src/contracts/helpers/TxBuilder.sol";
import {DAppConfig, UserOperation, SolverOperation} from "../src/contracts/types/CallTypes.sol";
import {Verification} from "../src/contracts/types/VerificationTypes.sol";


import {SwapIntentController, SwapIntent, Condition} from "../src/contracts/examples/intents-example/SwapIntent.sol";

import {SolverBase} from "../src/contracts/solver/SolverBase.sol";



contract AccountingTest is BaseTest {

    SwapIntentController public swapIntentController;
    TxBuilder public txBuilder;
    Sig public sig;

    ERC20 DAI = ERC20(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    address DAI_ADDRESS = address(DAI);

    struct Sig {
        uint8 v;
        bytes32 r;
        bytes32 s;
    }


    function setUp() public virtual override {
        BaseTest.setUp();

        // Creating new gov address (ERR-V49 OwnerActive if already registered with controller) 
        governancePK = 11112;
        governanceEOA = vm.addr(governancePK);

        // Deploy new SwapIntent Controller from new gov and initialize in Atlas
        vm.startPrank(governanceEOA);
        swapIntentController = new SwapIntentController(address(escrow));        
        atlas.initializeGovernance(address(swapIntentController));
        atlas.integrateDApp(address(swapIntentController), address(swapIntentController));
        vm.stopPrank();

        txBuilder = new TxBuilder({
            controller: address(swapIntentController),
            escrowAddress: address(escrow),
            atlasAddress: address(atlas)
        });
    }


    function testSolverEthValueIsNotDoubleCountedViaSurplusAccounting() public {
        // Things Noticed:
        // The metacall tx succeeds even though the user's intent was not fulfilled (fails before calling solver)
        // This ^ is intended behaviour with the returns gracefully thing to record nonce,
        // but might be misleading UX

        // TODO New Plan
        // 1. How do ETH funds flow in before escrowed?
        // 2. Find accounting logic for escrowed gas balances of all solvers (source of lent ETH)
        //  -> Escrow.sol L489 - checks if solver escrow can meet estimated solver gas cost
        // 3. Find gas donation accounting logic
        //  -> Escrow.sol donateToBundler(addr surplusRecipient) ????
        // Any donation/repayment would be double counted

        // msg.value settings
        uint256 userMsgValue = 2e18;
        uint256 solverMsgValue = 1e18; // TODO works with 0, breaks with 1e18
        uint256 gasCostCoverAmount = 1e16; // 0.01 ETH - gas is about 0.00164 ETH
        uint256 atlasStartBalance = solverMsgValue * 12 / 10; // Extra in Atlas for call gas cost

        deal(userEOA, userMsgValue);

        // TODO trying to give Atlas ETH in a more tracked way:
        // deal(address(atlas), atlasStartBalance); // Solver borrows 1 ETH from Atlas balance
        vm.prank(solverTwoEOA);
        atlas.deposit{value: atlasStartBalance}(solverTwoEOA); // Solver borrows 1 ETH from Atlas balance

        console.log("atlas balalnnce", address(atlas).balance);

        // Same as basic SwapIntent test - Swap 10 WETH for 20 DAI
        Condition[] memory conditions;
        SwapIntent memory swapIntent = SwapIntent({
            tokenUserBuys: DAI_ADDRESS,
            amountUserBuys: 20e18,
            tokenUserSells: WETH_ADDRESS,
            amountUserSells: 10e18,
            auctionBaseCurrency: address(0),
            solverMustReimburseGas: false,
            conditions: conditions
        });

        // Solver deploys the RFQ solver contract (defined at bottom of this file)
        vm.startPrank(solverOneEOA);
        SimpleRFQSolver rfqSolver = new SimpleRFQSolver(address(atlas));
        atlas.deposit{value: gasCostCoverAmount}(solverOneEOA);
        vm.stopPrank();

        // Give 20 DAI to RFQ solver contract
        deal(DAI_ADDRESS, address(rfqSolver), swapIntent.amountUserBuys);
        assertEq(DAI.balanceOf(address(rfqSolver)), swapIntent.amountUserBuys, "Did not give enough DAI to solver");

        // Input params for Atlas.metacall() - will be populated below
        DAppConfig memory dConfig = txBuilder.getDAppConfig();
        UserOperation memory userOp;
        SolverOperation[] memory solverOps = new SolverOperation[](1);
        Verification memory verification;

        vm.startPrank(userEOA);
        address executionEnvironment = atlas.createExecutionEnvironment(dConfig);
        vm.stopPrank();
        vm.label(address(executionEnvironment), "EXECUTION ENV");

        // userCallData is used in delegatecall from exec env to control, calling stagingCall
        // first 4 bytes are "userSelector" param in stagingCall in ProtocolControl - swap() selector
        // rest of data is "userData" param
        
        // swap(SwapIntent calldata) selector = 0x98434997
        bytes memory userCallData = abi.encodeWithSelector(SwapIntentController.swap.selector, swapIntent);

        // Builds the metaTx and to parts of userCall, signature still to be set
        userOp = txBuilder.buildUserOperation({
            from: userEOA,
            to: address(swapIntentController),
            maxFeePerGas: tx.gasprice + 1,
            value: 0,
            data: userCallData
        });

        // User signs the userCall
        (sig.v, sig.r, sig.s) = vm.sign(userPK, atlas.getUserOperationPayload(userOp));
        userOp.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Build solver calldata (function selector on solver contract and its params)
        bytes memory solverOpData = abi.encodeWithSelector(
            SimpleRFQSolver.fulfillRFQ.selector, 
            swapIntent,
            executionEnvironment
        );

        // Builds the SolverCall
        solverOps[0] = txBuilder.buildSolverOperation({
            userOp: userOp,
            dConfig: dConfig,
            solverOpData: solverOpData,
            solverEOA: solverOneEOA,
            solverContract: address(rfqSolver),
            bidAmount: 0
        });

        solverOps[0].call.value = solverMsgValue;

        // Solver signs the solverCall
        (sig.v, sig.r, sig.s) = vm.sign(solverOnePK, atlas.getSolverPayload(solverOps[0].call));
        solverOps[0].signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Frontend creates verification calldata after seeing rest of data
        verification = txBuilder.buildVerification(governanceEOA, dConfig, userOp, solverOps);

        // Frontend signs the verification payload
        (sig.v, sig.r, sig.s) = vm.sign(governancePK, atlas.getVerificationPayload(verification));
        verification.signature = abi.encodePacked(sig.r, sig.s, sig.v);

        // Check user token balances before
        uint256 userWethBalanceBefore = WETH.balanceOf(userEOA);
        uint256 userDaiBalanceBefore = DAI.balanceOf(userEOA);

        vm.prank(userEOA); // Burn all users WETH except 10 so logs are more readable
        WETH.transfer(address(1), userWethBalanceBefore - swapIntent.amountUserSells);
        userWethBalanceBefore = WETH.balanceOf(userEOA);

        assertTrue(userWethBalanceBefore >= swapIntent.amountUserSells, "Not enough starting WETH");

        console.log("\nBEFORE METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(rfqSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(rfqSolver)));
        console.log(""); // give space for internal logs

        vm.startPrank(userEOA);
        
        assertFalse(atlas.testUserOperation(userOp), "userOp tested true");
        
        WETH.approve(address(atlas), swapIntent.amountUserSells);

        assertTrue(atlas.testUserOperation(userOp), "userOp tested false");
        assertTrue(atlas.testUserOperation(userOp.call), "userOp.call tested false");

        console.log("user eth balance", address(userEOA).balance);

        // TODO start here - maybe see if msgValue comes from somewhere else? Focus on solver value 
        atlas.metacall{value: 0}({
            dConfig: dConfig,
            userOp: userOp,
            solverOps: solverOps,
            verification: verification
        });
        vm.stopPrank();

        console.log("\nAFTER METACALL");
        console.log("User WETH balance", WETH.balanceOf(userEOA));
        console.log("User DAI balance", DAI.balanceOf(userEOA));
        console.log("Solver WETH balance", WETH.balanceOf(address(rfqSolver)));
        console.log("Solver DAI balance", DAI.balanceOf(address(rfqSolver)));

        // Check user token balances after
        assertEq(WETH.balanceOf(userEOA), userWethBalanceBefore - swapIntent.amountUserSells, "Did not spend enough WETH");
        assertEq(DAI.balanceOf(userEOA), userDaiBalanceBefore + swapIntent.amountUserBuys, "Did not receive enough DAI");

    }

}


// This solver magically has the tokens needed to fulfil the user's swap.
// This might involve an offchain RFQ system
contract SimpleRFQSolver is SolverBase {
    constructor(address atlas) SolverBase(atlas, msg.sender) {}

    function fulfillRFQ(
        SwapIntent calldata swapIntent,
        address executionEnvironment
    ) public payable {
        console.log("SEARCHER START");
        console.log("msg.value in solver", msg.value);
        require(ERC20(swapIntent.tokenUserSells).balanceOf(address(this)) >= swapIntent.amountUserSells, "Did not receive enough tokenIn");
        require(ERC20(swapIntent.tokenUserBuys).balanceOf(address(this)) >= swapIntent.amountUserBuys, "Not enough tokenOut to fulfill");
        ERC20(swapIntent.tokenUserBuys).transfer(executionEnvironment, swapIntent.amountUserBuys);
    }

    // This ensures a function can only be called through metaFlashCall
    // which includes security checks to work safely with Atlas
    modifier onlySelf() {
        require(msg.sender == address(this), "Not called via metaFlashCall");
        _;
    }

    fallback() external payable {}
    receive() external payable {}
}