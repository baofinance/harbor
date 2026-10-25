// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {BaoTest} from "@bao-test/BaoTest.sol";
import {IBaoOwnable} from "@bao/interfaces/IBaoOwnable.sol";
import {MockERC20} from "@bao-test/mocks/MockERC20.sol";

import {IRepayment_v1} from "@harbor/interfaces/IRepayment_v1.sol";
import {HarborDeployRun} from "@harbor-test/HarborDeployRun.sol";

/// @notice The deploy chain places the repayment contract at its predicted address, records the debts given, and leaves
///         it owned by the run's owner.
contract RepaymentDeployTest is BaoTest {
    address private constant RUN_OWNER = address(0x0117);
    address private constant RUN_TREASURY = address(0x7EA5);

    HarborDeployRun internal run;
    address internal token;

    function setUp() public {
        run = new HarborDeployRun(RUN_OWNER, RUN_TREASURY, "test_repayment", "mainnet", HarborDeployRun.Cut.Whole);
        run.ensureFactory();
        token = address(new MockERC20("wrapped staked ether", "wstETH", 18));
    }

    /// @notice The proxy lands at the address predicted from the run's salt prefix and the incident's key, with the debts
    ///         recorded and the run's owner as its owner.
    function test_deployRepayment_atThePredictedAddressWithTheDebts() public {
        address[] memory accounts = new address[](2);
        accounts[0] = makeAddr("alice");
        accounts[1] = makeAddr("bob");
        uint256[] memory debts = new uint256[](2);
        debts[0] = 10 ether;
        debts[1] = 3 ether;

        address predicted = run.rebalanceDilutionRepaymentAddress();
        address repayment = run.deployRepayment(token, accounts, debts);

        assertEq(repayment, predicted, "deployed where predicted");
        assertEq(IRepayment_v1(repayment).TOKEN(), token, "the debt token");
        assertEq(IRepayment_v1(repayment).debt(accounts[0]), 10 ether, "alice's debt");
        assertEq(IRepayment_v1(repayment).debt(accounts[1]), 3 ether, "bob's debt");
        assertEq(IRepayment_v1(repayment).totalDebt(), 13 ether, "the total");
        assertEq(IBaoOwnable(repayment).owner(), RUN_OWNER, "owned by the run's owner");
    }
}
