// SPDX-License-Identifier: MIT
pragma solidity >=0.8.28 <0.9.0;

import {DeploymentTypes} from "./DeploymentTypes.sol";

/// @notice Shared type definitions for deployment state management.
library DeploymentTypes {
    enum FragmentKind {
        Peg,
        Collateral,
        ContractRole,
        MinterMarket,
        PriceMarket
    }

    struct FragmentDescriptor {
        FragmentKind kind;
        string key;
    }

    struct PegFragment {
        string id;
    }

    struct CollateralFragment {
        string id;
    }

    struct ContractRole {
        string id;
    }

    struct MinterMarket {
        PegFragment peg;
        CollateralFragment collateral;
    }

    struct PriceMarket {
        CollateralFragment collateral;
        PegFragment peg;
    }

    struct ImplementationRecord {
        string proxy;
        string contractSource;
        string contractType;
        address implementation;
        uint64 deploymentTime;
    }

    struct ProxyRecord {
        string id;
        FragmentDescriptor fragment;
        address proxy;
        address implementation;
        string salt;
        uint64 deploymentTime;
    }

    struct PendingUpgrade {
        FragmentDescriptor fragment;
        bytes32 versionTag;
    }

    struct State {
        string network;
        string saltPrefix;
        bool useLocal;
        ImplementationRecord[] implementations;
        ProxyRecord[] proxies;
        PendingUpgrade[] pendingUpgrades;
        address baoFactory;
    }
}
