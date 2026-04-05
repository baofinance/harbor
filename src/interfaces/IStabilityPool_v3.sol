// SPDX-License-Identifier: MIT

pragma solidity >=0.8.28 <0.9.0;

import {IMultipleRewardAccumulator_v3} from "src/interfaces/IMultipleRewardAccumulator_v3.sol";

/// @notice StabilityPool v3 additions: unified claim interface.
/// @dev Does NOT inherit IStabilityPool — the SP_v3 contract inherits both separately.
// solhint-disable-next-line contract-name-capwords
interface IStabilityPool_v3 is IMultipleRewardAccumulator_v3 {}
