// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ForkBase} from "./ForkBase.sol";
import {CollectionGame} from "../../src/game/CollectionGame.sol";

/// @notice Keeper gas per prize on the launch board (run with `--isolate`): a sync that books one draw and replaces
///         the prize it took, three times per prize type, a booking-only sync, and one sync that books and replaces
///         ten draws, and a governance board change (rebinding 100 rows). Receipt: docs/receipts/gas-prizes.json.
contract GasPrizesForkTest is ForkBase {
    address alice = makeAddr("cg.player.alice");
    string internal j;

    function setUp() public {
        deployChecks();
        launchGame(0.25 ether);
    }

    function _replaceGas(uint256 backing, uint256 nonce) internal returns (uint256 used) {
        uint256 r = pull(alice);
        vm.roll(block.number + 3);
        deliverWord(r, wordFor(backing));
        pool.processAcquisitions(10);
        window();
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        used = g - gasleft();
        nonce;
    }

    function test_gasPerPrize() public {
        accrueFees(20 ether); // the vault can always fund replacements: every measured sync restocks fully
        vm.prank(owner);
        sys.game.setBoardParams(3, 10, 20); // measure batches of 10 (the launch board lists 8 per call)
        // booking only: a draw settles, no maintenance window has passed and fewer than three rows wait
        pullAndSettle(alice, 777);
        uint256 g = gasleft();
        vm.prank(keeper);
        sys.game.sync();
        j = vm.serializeUint("prizes", "sync_book_1_only", g - gasleft());
        assertEq(sys.game.liveCount(), sys.game.boardSize() - 1, "nothing listed");
        window();
        syncAll();
        // k draws booked and replaced by one keeper call (realistic batches; at most 10 prizes listed per call, D61)
        uint256[4] memory ks = [uint256(3), 5, 8, 10];
        for (uint256 t; t < 4; ++t) {
            for (uint256 i; i < ks[t]; ++i) {
                pullAndSettle(alice, uint256(keccak256(abi.encode("batch", t, i))));
            }
            window();
            g = gasleft();
            vm.prank(keeper);
            sys.game.sync();
            j = vm.serializeUint("prizes", string.concat("sync_book_", vm.toString(ks[t]), "_replace_", vm.toString(ks[t])), g - gasleft());
            assertEq(sys.game.liveCount(), sys.game.boardSize(), "all replaced");
        }
        uint256[8] memory tiers =
            [uint256(0.01 ether), 0.02 ether, 0.03 ether, 0.04 ether, 0.05 ether, 0.1 ether, 0.15 ether, 0.5 ether];
        string[8] memory names =
            ["shape_001", "pack_002", "pack_003", "pack_004", "shape_005", "shape_010", "pack_015", "shape_050"];
        for (uint256 t; t < 8; ++t) {
            uint256 sum;
            for (uint256 k; k < 3; ++k) {
                sum += _replaceGas(tiers[t], k);
                assertEq(sys.game.liveCount(), sys.game.boardSize(), "replaced");
            }
            j = vm.serializeUint("prizes", string.concat("sync_book_1_replace_", names[t]), sum / 3);
        }
        // a pattern change: the launch pattern in reverse order (stored and validated; nothing listed moves)
        uint256[] memory p = _boardPattern();
        uint256[] memory r = new uint256[](p.length);
        for (uint256 i; i < p.length; ++i) {
            r[i] = p[p.length - 1 - i];
        }
        vm.prank(owner);
        g = gasleft();
        sys.game.setPattern(r);
        j = vm.serializeUint("prizes", "set_pattern_50_rows", g - gasleft());
        vm.writeJson(j, "docs/receipts/gas-prizes.json");
    }
}
