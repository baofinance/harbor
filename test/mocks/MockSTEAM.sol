// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {MintableBurnableERC20_v1} from "@bao/MintableBurnableERC20_v1.sol";

// serves no other purpose than making the foundry traces more informative
contract MockSTEAM is MintableBurnableERC20_v1 {}
