// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";

import { LoggingTest, ILog, LogConsole } from "./LoggingTest.sol";

contract LogDebug is ILog {
    // logs to a string for comparison purposes
    string public result;

    constructor() {
        result = "";
    }

    function log(string calldata message) external override {
        result = message;
    }
}

contract TestLoggingTest is LoggingTest {
    LogDebug testLogDevice;

    function setUp() public {
        testLogDevice = new LogDebug();
        setLogger(testLogDevice);
    }

    function test_log() public /*skipMe*/ {
        // console.log("hello world");
        l("hello world");
        assertEq(testLogDevice.result(), "hello world");
    }

    function test_value() public {
        l(v(123));
        assertEq(testLogDevice.result(), "123");

        l(v(2000));
        assertEq(testLogDevice.result(), "2,000");

        l(v(123).v(456));
        assertEq(testLogDevice.result(), "123 456");

        l(v(123).v(456));
        assertEq(testLogDevice.result(), "123 456");
    }

    function test_separator() public {
        l(v(123).comma().v(456));
        assertEq(testLogDevice.result(), "123, 456");

        l(v(123).comma().v(456).v(789));
        assertEq(testLogDevice.result(), "123, 456 789");

        l(v(123).v(456).comma().v(789));
        assertEq(testLogDevice.result(), "123 456, 789");

        l(v(123).v(456).comma().v(789).v(100));
        assertEq(testLogDevice.result(), "123 456, 789 100");

        l(v(123).none().v(456));
        assertEq(testLogDevice.result(), "123456");

        l(v(123).colon().v(456));
        assertEq(testLogDevice.result(), "123: 456");

        l(v(123).semi().v(456));
        assertEq(testLogDevice.result(), "123; 456");
    }

    function test_defaultSeparator() public {
        l(b(v(100).comma().v(200)));
        assertEq(testLogDevice.result(), "(100, 200)", "complex value with comma");

        l(b(comma().v(100).v(200)));
        assertEq(testLogDevice.result(), "(100, 200)", "complex value with default comma");

        l(b(v(100).comma().v(200).v(300)));
        assertEq(testLogDevice.result(), "(100, 200 300)", "complex value, mixed commas");

        l(b(comma().v(100).v(200).v(300)));
        assertEq(testLogDevice.result(), "(100, 200, 300)", "complex value multiple default comma");

        l(b(colon().v(100).v(200).v(300)));
        assertEq(testLogDevice.result(), "(100: 200: 300)", "complex value multiple default colon");

        l(b(semi().v(100).v(200).v(300)));
        assertEq(testLogDevice.result(), "(100; 200; 300)", "complex value multiple default semi");

        l(b(none().v(100).v(200).v(300)));
        assertEq(testLogDevice.result(), "(100200300)", "complex value multiple default none");

        l(b(colon().comma().v(100).v(200).v(300)));
        assertEq(testLogDevice.result(), "(100: 200: 300)", "complex value default colon, mixed in comma 1");

        l(b(colon().v(100).comma().v(200).v(300)));
        assertEq(testLogDevice.result(), "(100, 200: 300)", "complex value default colon, mixed in comma 2");

        l(b(colon().v(100).v(200).comma().v(300)));
        assertEq(testLogDevice.result(), "(100: 200, 300)", "complex value default colon, mixed in comma 3");

        l(b(colon().v(100).v(200).v(300).comma()));
        assertEq(testLogDevice.result(), "(100: 200: 300)", "complex value default colon, mixed in comma 4");
    }

    function test_brackets() public {
        l(b(v(123)));
        assertEq(testLogDevice.result(), "(123)", "simple brackets");

        l(b(v(123).v(456)));
        assertEq(testLogDevice.result(), "(123 456)", "double brackets");

        l(v(123).b(v(456)));
        assertEq(testLogDevice.result(), "123 (456)", "complex single brackets");

        /*
        l(b(v(123).v(456).comma().v(789).v(100)));
        assertEq(testLogDevice.result(), "(123 456, 789 100)", "brackets round comma");

        l(v(123).b(v(456).comma().v(789).v(100)));
        assertEq(testLogDevice.result(), "123 (456, 789 100)", "brackets round comma 2");

        l(v(123).v(456).comma().b(v(789).v(100)));
        assertEq(testLogDevice.result(), "123 456, (789 100)", "brackets round comma 3");

        l(v(123).v(456).comma().v(789).b(v(100)));
        assertEq(testLogDevice.result(), "123 456, 789 (100)", "brackets round comma 4");

        l(b(v(123).v(456).comma().v(789)).v(100));
        assertEq(testLogDevice.result(), "(123 456, 789) 100", "brackets round comma 5");

        l(b(v(123).v(456).comma()).v(789).v(100)); // comma has no effect
        assertEq(testLogDevice.result(), "(123 456) 789 100", "brackets round comma 6");

        l(b(v(123).v(456)).comma().v(789).v(100));
        assertEq(testLogDevice.result(), "(123 456), 789 100", "brackets round comma 7");

        l(b(v(123)).v(456).comma().v(789).v(100));
        assertEq(testLogDevice.result(), "(123) 456, 789 100", "brackets round comma 8");

        l(q(v(123)));
        assertEq(testLogDevice.result(), "'123'", "simple quotes");

        l(qq(v(123)));
        assertEq(testLogDevice.result(), '"123"', "simple double quotes");
        */
    }

    function test_name() public {
        l(n("name").v(100));
        assertEq(testLogDevice.result(), "name=100", "simple name=value");

        l(n("name").b(v(100).v(200)));
        assertEq(testLogDevice.result(), "name=(100 200)", "complex value");

        l(n("name").b(comma().v(100).v(200)));
        assertEq(testLogDevice.result(), "name=(100, 200)", "complex value");
    }

    function test_indent() public {}
}
