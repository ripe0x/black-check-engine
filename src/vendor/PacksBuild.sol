// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// Compiles the vendored Draw Packs contracts (lib/shape-packs, MIT) so the deploy routine can create a dedicated
// instance from their artifacts. Nothing here is deployed.
import {ShapePacks} from "packs/ShapePacks.sol";
import {ShapePackRenderer} from "packs/ShapePackRenderer.sol";
