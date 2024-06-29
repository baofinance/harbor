// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// creates arrays of uint, int and address

contract ArrayMaker {
    function ua() internal pure returns (uint[] memory result) {
        result = new uint[](0);
    }
    function ua(uint a_) internal pure returns (uint[] memory result) {
        result = new uint[](1);
        result[0] = a_;
    }
    function ua(uint a_, uint b) internal pure returns (uint[] memory result) {
        result = new uint[](2);
        result[0] = a_;
        result[1] = b;
    }
    function ua(uint a_, uint b, uint c) internal pure returns (uint[] memory result) {
        result = new uint[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function ua(uint a_, uint b, uint c, uint d) internal pure returns (uint[] memory result) {
        result = new uint[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e) internal pure returns (uint[] memory result) {
        result = new uint[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function ua(uint a_, uint b, uint c, uint d, uint e, uint f) internal pure returns (uint[] memory result) {
        result = new uint[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function ia() internal pure returns (int[] memory result) {
        result = new int[](0);
    }
    function ia(int a_) internal pure returns (int[] memory result) {
        result = new int[](1);
        result[0] = a_;
    }
    function ia(int a_, int b) internal pure returns (int[] memory result) {
        result = new int[](2);
        result[0] = a_;
        result[1] = b;
    }
    function ia(int a_, int b, int c) internal pure returns (int[] memory result) {
        result = new int[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function ia(int a_, int b, int c, int d) internal pure returns (int[] memory result) {
        result = new int[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function ia(int a_, int b, int c, int d, int e) internal pure returns (int[] memory result) {
        result = new int[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function ia(int a_, int b, int c, int d, int e, int f) internal pure returns (int[] memory result) {
        result = new int[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }

    function aa() internal pure returns (address[] memory result) {
        result = new address[](0);
    }
    function aa(address a_) internal pure returns (address[] memory result) {
        result = new address[](1);
        result[0] = a_;
    }
    function aa(address a_, address b) internal pure returns (address[] memory result) {
        result = new address[](2);
        result[0] = a_;
        result[1] = b;
    }
    function aa(address a_, address b, address c) internal pure returns (address[] memory result) {
        result = new address[](3);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
    }
    function aa(address a_, address b, address c, address d) internal pure returns (address[] memory result) {
        result = new address[](4);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
    }
    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e
    ) internal pure returns (address[] memory result) {
        result = new address[](5);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
    }
    function aa(
        address a_,
        address b,
        address c,
        address d,
        address e,
        address f
    ) internal pure returns (address[] memory result) {
        result = new address[](6);
        result[0] = a_;
        result[1] = b;
        result[2] = c;
        result[3] = d;
        result[4] = e;
        result[5] = f;
    }
}
