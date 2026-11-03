// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IFWAPool} from "../interfaces/IFWA.sol";

interface IGameSync {
    function upkeep(uint256 maxCount) external returns (uint256 work);
    function vault() external view returns (address);
    function pool() external view returns (IFWAPool);
    function poolOwner() external view returns (IPrizeSource);
}

/// @dev The pool owner's prize contracts: the Shapes and Packs the game lists, the ones a player redeems here.
interface IPrizeSource {
    function shapes() external view returns (address);
    function packs() external view returns (address);
}

/// @dev Shapes and Packs both redeem a token for its backing, paid to its owner; Shapes also in a batch.
interface IRedeemable {
    function transferFrom(address from, address to, uint256 id) external;
    function redeem(uint256 id) external;
    function redeemBatch(uint256[] calldata ids) external returns (uint256);
}

interface IVaultSweep {
    function sweep() external returns (uint256 forwarded);
}

/// @title DrawRouter
/// @notice A player's draw in one transaction, doing the protocol's upkeep on the way:
///         1. settle up to `settle` draws already waiting in the pool's queue (FWA `processAcquisitions`);
///         2. buy `count` draws for the caller;
///         3. if `syncCount` and `upkeepGas` are not 0, run the game's `upkeep` (`sync`'s work: book settled draws,
///            replace won prizes, pay out surplus, reopen the gate) with at most `upkeepGas` gas, then meter available
///            ETH into the vault's live bid (`sweep`, a no-op inside its cooldown) with a fixed gas allowance.
///         With `count` 0 it only does the upkeep (the site's "unstick" when a booking backlog has closed purchases).
///         A player's draw does that work at the player's cost and is not paid for it: the game's `upkeep` pays nobody
///         and the vault's sweep reward goes back to the vault. Keepers are paid by calling `sync` and
///         `sweep` themselves.
/// @dev Stateless, no owner, no privileges, bound to one game at deployment (`game`): a draw names it, so a caller
///      handed a fake game and pool cannot pay or redeem into them here. It is wired into
///      nothing: FWA treats it as an ordinary payer and the caller as
///      the purchaser (NFTs, refund credit and delivery rights all go to the caller). Settlement and upkeep never
///      block the purchase (each is tried on its own, the upkeep inside its own gas budget, with `TAIL_GAS` kept back
///      for the steps after it), and upkeep runs after the purchase so a listing it adds cannot change the inventory
///      version the player's quote was made on. Heavy maintenance (a full listing batch, board growth) is left to
///      keepers' own `sync` calls whenever it does not fit the player's budget: the site measures the upkeep first
///      (`measureUpkeep`) and asks for it only when it is cheap. Every wei left at the end (FWA's change,
///      anything sent here by mistake) goes to the caller. Replaceable at any time.
///      `redeemAndDraw` is the one path that moves a player's tokens: it needs the player's approval on Shapes and
///      Packs, takes only `msg.sender`'s own tokens, only on the game's own Shapes and Packs contracts, redeems them
///      at once and holds nothing after the transaction.
contract DrawRouter is ReentrancyGuard {
    /// @notice Gas for the vault's `sweep` after the upkeep, with room to spare: a metered step, or one that also splits
    ///         the fee overflow to the burner.
    uint256 public constant SWEEP_GAS = 250_000;
    /// @notice Gas kept back after the upkeep: the sweep, its pay and the game's to the vault, and the change to the
    ///         caller.
    uint256 public constant TAIL_GAS = SWEEP_GAS + 100_000;

    /// @notice The transaction's gas limit leaves less than the upkeep budget the caller asked for (plus `TAIL_GAS`).
    ///         Never reached when the gas limit is estimated: it makes the estimate include the budget.
    error UpkeepGas();
    /// @notice `pool` is not `game.pool()`.
    error WrongPool();
    /// @notice The draw names a game other than the one this router serves.
    error WrongGame();

    /// @notice The one game this router draws for, fixed at deployment.
    IGameSync public immutable game;

    constructor(IGameSync game_) {
        game = game_;
    }

    /// @notice A draw's parameters, as `draw` takes them.
    struct DrawParams {
        IFWAPool pool;
        IGameSync game;
        uint256 settle;
        uint256 syncCount;
        uint256 upkeepGas;
        uint256 count;
        uint256 maxFee;
        uint256 minWeightedValue;
        uint256 maxSlippageBps;
        uint256 expectedInventoryVersion;
        uint256 deadline;
    }

    receive() external payable {}

    /// @notice What the game's upkeep would cost now: runs `upkeep(syncCount)` and reports whether it did any work and
    ///         the gas it used. Meant for `eth_call` (its effects are discarded there); a site sets a draw's
    ///         `upkeepGas` from it. In a transaction it is an ordinary unpaid `upkeep`. (Not `sync`: a paid sync of light
    ///         work is refused while players are drawing.)
    function measureUpkeep(IGameSync game_, uint256 syncCount) external nonReentrant returns (bool ran, uint256 gasUsed) {
        uint256 g = gasleft();
        try game_.upkeep(syncCount) returns (uint256 work) {
            ran = work != 0;
        } catch {}
        gasUsed = g - gasleft();
        uint256 change = address(this).balance;
        if (change != 0) SafeTransferLib.safeTransferETH(msg.sender, change);
    }

    /// @notice The price of `count` draws once up to `settle` waiting draws are settled (settling removes prizes, so
    ///         it moves the ticket). Meant for `eth_call`, where the settlement is only simulated; called in a
    ///         transaction it settles for real, exactly as `processAcquisitions` would. FWA's randomness fee depends
    ///         on the gas price: simulate with the price the draw will use.
    function quote(IFWAPool pool, uint256 settle, uint256 count)
        external
        returns (uint256 fee, uint256 vrf, uint256 total)
    {
        if (settle != 0) {
            try pool.processAcquisitions(settle) {} catch {}
        }
        return pool.quoteAcquisitionPrice(count);
    }

    /// @notice Settles up to `settle` ready draws, buys `count` draws for the caller with the attached ETH under FWA's
    ///         own guards (fee ceiling, pool-value floor, slippage, inventory version, deadline), then, if `syncCount`
    ///         and `upkeepGas` are not 0, runs `game.upkeep(syncCount)` with at most `upkeepGas` gas and the vault's
    ///         `sweep`. An upkeep that needs more than `upkeepGas` fails on its own (its gas is
    ///         spent, the draw stands). Unpaid: the sweep reward goes back to the vault.
    function draw(
        IFWAPool pool,
        IGameSync game_,
        uint256 settle,
        uint256 syncCount,
        uint256 upkeepGas,
        uint256 count,
        uint256 maxFee,
        uint256 minWeightedValue,
        uint256 maxSlippageBps,
        uint256 expectedInventoryVersion,
        uint256 deadline
    ) external payable nonReentrant returns (uint256[] memory requestIds) {
        return _draw(
            DrawParams(
                pool,
                game_,
                settle,
                syncCount,
                upkeepGas,
                count,
                maxFee,
                minWeightedValue,
                maxSlippageBps,
                expectedInventoryVersion,
                deadline
            ),
            msg.value
        );
    }

    /// @notice Redeems the caller's won prizes and draws with what they pay, in one transaction: takes the caller's
    ///         Shapes `shapeIds` and Packs `packIds` (the game's own Shapes and Packs contracts, read from the game's
    ///         pool owner; the caller must have approved this router on them), redeems them for their backing, then
    ///         draws as `draw` does with that ETH plus any attached ETH. FWA keeps what the draws cost; the rest comes
    ///         back to the caller with the change. With `count` 0 it only redeems (and runs any upkeep asked for).
    function redeemAndDraw(DrawParams calldata p, uint256[] calldata shapeIds, uint256[] calldata packIds)
        external
        payable
        nonReentrant
        returns (uint256[] memory requestIds)
    {
        if (p.game != game) revert WrongGame();
        IPrizeSource prizes = game.poolOwner();
        if (shapeIds.length != 0) {
            IRedeemable shapes = IRedeemable(prizes.shapes());
            // only the caller's own tokens: `transferFrom` from anyone else reverts
            for (uint256 i; i < shapeIds.length; ++i) {
                shapes.transferFrom(msg.sender, address(this), shapeIds[i]);
            }
            shapes.redeemBatch(shapeIds);
        }
        if (packIds.length != 0) {
            IRedeemable packs = IRedeemable(prizes.packs());
            for (uint256 i; i < packIds.length; ++i) {
                packs.transferFrom(msg.sender, address(this), packIds[i]);
                packs.redeem(packIds[i]);
            }
        }
        // what the redeems paid plus the attached ETH (and anything sent here by mistake, which goes to the caller
        // with the change in any case)
        return _draw(p, address(this).balance);
    }

    function _draw(DrawParams memory p, uint256 value) internal returns (uint256[] memory requestIds) {
        // the game must be this router's own, and the pool the game's: a caller handed another game, or a site whose
        // read RPC lies about `game.pool()`, could otherwise pay a fake pool
        if (p.game != game) revert WrongGame();
        if (address(p.pool) != address(game.pool())) revert WrongPool();
        if (p.settle != 0) {
            try p.pool.processAcquisitions(p.settle) {} catch {}
        }
        if (p.count == 0) {
            // upkeep only (e.g. when a booking backlog has closed purchases): no draw
        } else if (p.count == 1) {
            requestIds = new uint256[](1);
            requestIds[0] = p.pool.acquire{value: value}(
                msg.sender, p.maxFee, p.minWeightedValue, p.maxSlippageBps, p.expectedInventoryVersion, p.deadline
            );
        } else {
            requestIds = p.pool.acquireBatch{value: value}(
                msg.sender, p.count, p.maxFee, p.minWeightedValue, p.maxSlippageBps, p.expectedInventoryVersion, p.deadline
            );
        }
        if (p.syncCount != 0 && p.upkeepGas != 0) {
            // the budget and the tail must both be there (a call receives at most 63/64 of what is left)
            if (gasleft() < p.upkeepGas + p.upkeepGas / 63 + TAIL_GAS) revert UpkeepGas();
            // a player's draw does the game's work at the player's cost, unpaid: `upkeep` pays nothing and the
            // vault's sweep reward goes back to the vault. Keepers are paid by calling `sync` and `sweep` directly.
            uint256 before = address(this).balance;
            try p.game.upkeep{gas: p.upkeepGas}(p.syncCount) {} catch {}
            address v = p.game.vault();
            try IVaultSweep(v).sweep{gas: SWEEP_GAS}() {} catch {}
            uint256 pay = address(this).balance - before;
            if (pay != 0) SafeTransferLib.forceSafeTransferETH(v, pay);
        }
        uint256 change = address(this).balance;
        if (change != 0) SafeTransferLib.safeTransferETH(msg.sender, change);
    }
}
