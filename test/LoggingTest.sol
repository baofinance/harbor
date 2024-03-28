// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import { Test } from "forge-std/Test.sol";
import { console2 as console } from "forge-std/console2.sol";

import { Useful } from "./Useful.sol";
// import {DateUtils} from "DateUtils/DateUtils.sol";

interface ILog {
    function log(string memory message) external;
}

contract LogConsole is ILog {
    function log(string memory message) public pure override {
        console.log(message);
    }
}

// log(v("name=").v("value").v("name2=").v("value2")) <--
// log(nv("name", "value").nv("name2", "value"))

// looks like there's a limit to how many of a contract can be created
// so need to externalise the stack of logbuilders that are created by
// LoggingTest
// to do this we create a struct containing the LogBuilder data,
// in LoggingTest we create an array od those structs and push and pop to make a stack
//
contract LogBuilder {
    struct LogBuilderState {
        string separator;
        string defaultSeparator;
        string buffer;
        string indent; // TODO: this is not part of the logBuilderState - move to LoggingTest
    }

    LogBuilderState[] public logBuilderStates;

    function pushState() public returns (LogBuilder) {
        logBuilderStates.push(
            LogBuilderState({
                separator: "", // no separator at first, then switches to the default
                defaultSeparator: " ", // default is a space
                buffer: "", // buffer is empty
                indent: "" // no indent
            })
        );
        console.log("<-LogBuilder:pushState(), new length=%d", logBuilderStates.length);
        return this;
    }

    function popState() public returns (LogBuilder) {
        logBuilderStates.pop();
        // console.log("->LogBuilder:popState(), new length=%d", logBuilderStates.length);
        return this;
    }

    function last() public view returns (uint256) {
        return logBuilderStates.length - 1;
    }

    function setDefaultSeparator(string memory sep) public {
        logBuilderStates[last()].defaultSeparator = sep;
    }

    function flush() public returns (string memory result) {
        // TODO: this should only happen when there is one state left;
        result = Useful.concat(string(logBuilderStates[last()].indent), string(logBuilderStates[last()].buffer));
        // console.log("->LogBuilder:flush() '%s'", result);
        logBuilderStates[last()].buffer = "";
    }

    function append(string memory suffix) private {
        // each value is separated from the previous, unless it's the first
        // console.log("->LogBuilder:append('%s')", suffix);
        logBuilderStates[last()].buffer = Useful.concat(
            logBuilderStates[last()].buffer,
            (bytes(logBuilderStates[last()].buffer).length > 0) ? logBuilderStates[last()].separator : "",
            suffix
        );
        logBuilderStates[last()].separator = logBuilderStates[last()].defaultSeparator;
        // console.log("  buffer='%s'", logBuilderStates[last()].buffer);
    }

    function comma() public returns (LogBuilder) {
        logBuilderStates[last()].separator = ", ";
        return this;
    }

    function colon() public returns (LogBuilder) {
        logBuilderStates[last()].separator = ": ";
        return this;
    }

    function semi() public returns (LogBuilder) {
        logBuilderStates[last()].separator = "; ";
        return this;
    }

    function none() public returns (LogBuilder) {
        logBuilderStates[last()].separator = "";
        return this;
    }

    // log(v(1).v(2000)) =>1 2,000<=;
    function v(uint256 value) public returns (LogBuilder) {
        // console.log("->LogBuilder:v(%d)", value);
        append(Useful.toStringThousands(value, Useful.comma));
        return this;
    }

    function v_(uint256 value) public returns (LogBuilder) {
        append(Useful.toStringThousands(value, Useful.underscore));
        return this;
    }

    function v0(uint256 value) public returns (LogBuilder) {
        append(Useful.toString(value));
        return this;
    }

    // log(v0x(1)) =>0x1<=
    function v0x(uint256 value) public returns (LogBuilder) {
        append(Useful.toStringHex(value));
        return this;
    }

    function v$(uint256 value, uint256 digits) public returns (LogBuilder) {
        append(Useful.toStringScaled(value, digits));
        return this;
    }

    function v(string memory value) public returns (LogBuilder) {
        append(value);
        return this;
    }

    function n(string memory name) public returns (LogBuilder) {
        append(Useful.concat(name, "="));
        logBuilderStates[last()].separator = ""; // join the = with the value
        return this;
    }

    // log(v(1).comma().v_(2000)) =>1,2_000<=;

    // v_(2000) =>2_000<=

    // log(q(v(1).v(2))) =>'1 2'<=;
    function _bracket(string memory open, string memory close) internal returns (LogBuilder) {
        string memory lb = Useful.concat(open, logBuilderStates[last()].buffer, close);
        //popState();
        append(lb);
        return this;
    }

    function q(LogBuilder) public returns (LogBuilder) {
        return _bracket("'", "'");
    }

    function qq(LogBuilder) public returns (LogBuilder) {
        return _bracket('"', '"');
    }

    function bWithNewState(LogBuilder) public returns (LogBuilder) {
        // console.log("->LogBuilder:bWithNewState(LogBuilder.buffer='%s')", logBuilderStates[last()].buffer);
        logBuilderStates[last()].buffer = Useful.concat("(", logBuilderStates[last()].buffer, ")");
        return this;
    }

    function b(LogBuilder) public returns (LogBuilder) {
        // console.log("->LogBuilder:b(LogBuilder.buffer='%s')", logBuilderStates[last()].buffer);
        string memory lb = Useful.concat("(", logBuilderStates[last()].buffer, ")");
        popState();
        append(lb);
        return this;
    }
}

contract LoggingTest is Test {
    // TODO: add string matching so logging can be switched on for specific functions/contracts
    // for contracts we need to add the name to the constructor

    ILog private logDevice;
    LogBuilder logBuilder;

    constructor() {
        // Logger.setLoggingInstructions(vm.envOr("LOG", string("")));
        logDevice = new LogConsole();
        logBuilder = new LogBuilder();
    }

    modifier logMe(string memory functionName) {
        // TODO: check the logging state of this function from loggingInstructions
        string memory display = Useful.concat(functionName, "()");
        //pushLogging(display, logging); // keep the logging level
        _;
        //popLogging(display);
    }

    modifier skipMe() {
        vm.skip(true);
        _;
    }

    // override loggingInstructions
    function startLogging() public {
        //        console.log("+++");
        //        logging = true;
    }

    function stopLogging() public {
        //        console.log("---");
        //        logging = false;
    }

    function setLogger(ILog log) public {
        logDevice = log;
    }

    // logging functions
    // l - connects the logBuilder with the log device
    function l(LogBuilder lb) public {
        // console.log("->LoggingTest:l(LogBuilder)");
        logDevice.log(lb.flush());
        logBuilder.popState();
    }

    function l(string memory message) public {
        // console.log("->LoggingTest:l('%s')", message);
        logDevice.log(message);
    }

    // separator functions
    // TODO: consider rolling these into one function s() with a param
    function comma() public returns (LogBuilder) {
        logBuilder.pushState();
        logBuilder.setDefaultSeparator(", ");
        return logBuilder;
    }

    function colon() public returns (LogBuilder) {
        logBuilder.pushState();
        logBuilder.setDefaultSeparator(": ");
        return logBuilder;
    }

    function semi() public returns (LogBuilder) {
        logBuilder.pushState();
        logBuilder.setDefaultSeparator("; ");
        return logBuilder;
    }

    function none() public returns (LogBuilder) {
        logBuilder.pushState();
        logBuilder.setDefaultSeparator("");
        return logBuilder;
    }

    // delegation functions
    function v(uint256 value) public returns (LogBuilder) {
        // console.log("->LoggingTest:v(%d)", value);
        return logBuilder.pushState().v(value);
    }

    function v_(uint256 value) public returns (LogBuilder) {
        return logBuilder.pushState().v(value);
    }

    function v0(uint256 value) public returns (LogBuilder) {
        return logBuilder.pushState().v0(value);
    }

    function v0x(uint256 value) public returns (LogBuilder) {
        return logBuilder.pushState().v0x(value);
    }

    function v$(uint256 value, uint256 digits) public returns (LogBuilder) {
        return logBuilder.pushState().v$(value, digits);
    }

    function v(string memory value) public returns (LogBuilder) {
        return logBuilder.pushState().v(value);
    }

    function n(string memory name) public returns (LogBuilder) {
        return logBuilder.pushState().n(name);
    }

    function q(LogBuilder lb) public returns (LogBuilder) {
        return logBuilder.pushState().q(lb).popState();
    }

    function qq(LogBuilder lb) public returns (LogBuilder) {
        return logBuilder.pushState().qq(lb).popState();
    }

    function b(LogBuilder lb) public returns (LogBuilder) {
        // console.log("->LoggingTest:b(LogBuilder)");
        logBuilder.bWithNewState(lb);
        return logBuilder;
    }

    // TODO: remove all of the below
    function addIndent(string memory format) private view returns (string memory indented) {
        indented = format;
        //for (uint256 i = 0; i < Logger.previousLoggingStates.length; i++) {
        //    indented = Useful.concat("  ", indented);
        //}
    }

    bool private constant logging = true;

    function clog(string memory format) public view {
        if (logging) console.log(addIndent(format));
    }

    function clog(string memory format, address d) public view {
        if (logging) console.log(addIndent(format), d);
    }

    function clog(string memory format, string memory d) public view {
        if (logging) console.log(addIndent(format), d);
    }

    function clog(string memory format, bytes32 d) public view {
        if (logging) console.log(addIndent(format), uint256(d));
    }

    function clog(string memory format, bytes memory d) public view {
        if (logging) {
            console.log(addIndent(format), "->");
            console.logBytes(d); // TODO: somehow add indent
        }
    }

    function clog(string memory format, bool d) public view {
        if (logging) console.log(addIndent(format), d);
    }

    function clog(string memory format, uint256 d) public view {
        if (logging) console.log(addIndent(format), d);
    }

    function clog(string memory format, int256 d) public view {
        if (logging) console.log(addIndent(format), d);
    }

    function clog(string memory format, address d, address d2) public view {
        if (logging) console.log(addIndent(format), d, d2);
    }

    function clog(string memory format, uint256 d, uint256 d2) public view {
        if (logging) console.log(addIndent(format), d, d2);
    }

    function clog(string memory format, string memory d, string memory d2) public view {
        if (logging) console.log(addIndent(format), d, d2);
    }

    function clog(string memory format, string memory d, uint256 d2) public view {
        if (logging) console.log(addIndent(format), d, d2);
    }
}
