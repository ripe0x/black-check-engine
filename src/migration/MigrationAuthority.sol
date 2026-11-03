// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {Governed} from "../core/Governed.sol";

interface IMigratingGame {
    function retire() external;
    function retired() external view returns (bool);
}

interface IMigratingPoolOwner {
    function migrateApe(address to) external returns (bool found, uint256 tokenId);
}

interface IMigratingVault {
    function migrateCapital(address successor) external returns (uint256 amount);
}

interface IFeeHook {
    function setFeeRecipient(address recipient) external;
}

/// @title MigrationAuthority
/// @notice The only way the game ends or moves, and the only way trading fees change destination. Every action that
///         moves assets or fees to a new address is public `DELAY` (72 hours) before it can run, and runs only the code
///         that was proposed (the address's code hash is pinned at proposal). The one exception moves value only to
///         buybacks: `sunset`, instant.
///         - `propose(successor)`: after `DELAY`, anyone `execute`s. The first execution stops the game for good (the
///           FWA pool retires; settlement, refunds and deliveries continue) and points trading fees at the successor.
///           Anyone then runs `CollectionGame.retireStep` until the game has settled and returned all its ETH to the
///           vault, then `migrateApes` (batched) and `migrateCapital` send the Apes and the vault's ETH to the
///           successor. A later proposal (again `DELAY`) replaces the successor for whatever has not moved yet.
///         - `proposeFeeRecipient(recipient)`: after `DELAY`, anyone `executeFeeRecipient`s: trading fees go to the
///           recipient (for example a splitter that also funds another buyback) while the game runs on.
///         - `sunset()`: the owner, at once. The successor becomes the immutable `sunset` contract, which auctions the
///           Apes and sends every wei it receives to the CollectionBurner; trading fees go there too. Pending proposals
///           are cancelled. It can follow a migration that has started, for whatever has not moved yet.
///         Committed buyback ETH (the burner) never moves. The authority never holds assets.
contract MigrationAuthority is ReentrancyGuard, Governed {
    uint256 public constant DELAY = 72 hours;

    IMigratingGame public game;
    IMigratingPoolOwner public poolOwner;
    IMigratingVault public vault;
    IFeeHook public hook;
    /// @notice The built-in successor that auctions the Apes and burns everything (wired at deployment).
    address public sunsetter;

    address public pending;
    bytes32 public pendingCodeHash;
    uint256 public proposedAt;
    address public pendingFeeRecipient;
    bytes32 public pendingFeeCodeHash;
    uint256 public feeProposedAt;
    /// @notice Where the game's Apes and capital go (set by `execute` or `sunset`).
    address public successor;
    bool public started;
    uint256 public apesMigrated;
    uint256 public capitalMigrated;

    event Proposed(address indexed successor, bytes32 codeHash, uint256 executableAt);
    event Executed(address indexed successor, bool started);
    event FeeRecipientProposed(address indexed recipient, bytes32 codeHash, uint256 executableAt);
    event FeeRecipientExecuted(address indexed recipient);
    event Sunset(address indexed sunsetter);
    event ApesMigrated(address indexed successor, uint256 count);
    event CapitalMigrated(address indexed successor, uint256 amount);

    error NothingPending();
    error TooEarly();
    error NotStarted();
    error NotSettled();
    error CodeChanged();
    error NotAContract();
    error SunsetFinal();
    error Started();

    constructor(address admin_) Governed(admin_, true) {}

    /// @notice One-shot wiring by the deployer: the game's contracts, the hook and the sunset successor.
    function wire(address game_, address poolOwner_, address vault_, address hook_, address sunset_)
        external
        onlyWiring
    {
        if (sunset_.code.length == 0) revert NotAContract();
        game = IMigratingGame(game_);
        poolOwner = IMigratingPoolOwner(poolOwner_);
        vault = IMigratingVault(vault_);
        hook = IFeeHook(hook_);
        sunsetter = sunset_;
    }

    // ------------------------------------------------------------------ migration

    /// @notice Proposes `successor_`, a contract, executable after `DELAY`; its code is pinned. address(0) cancels.
    ///         Replaces any pending proposal and restarts the delay. Refused after a sunset: what the sunset was handed,
    ///         and everything still to reach it, goes to buybacks only.
    function propose(address successor_) external onlyOwner {
        if (successor == sunsetter) revert SunsetFinal();
        bytes32 h;
        if (successor_ != address(0)) {
            if (successor_.code.length == 0) revert NotAContract();
            h = successor_.codehash;
        }
        pending = successor_;
        pendingCodeHash = h;
        proposedAt = block.timestamp;
        emit Proposed(successor_, h, successor_ == address(0) ? 0 : block.timestamp + DELAY);
    }

    /// @notice Makes the pending proposal the successor, at least `DELAY` after it was proposed and only if its code
    ///         is unchanged. Anyone. The first execution stops the game. Trading fees follow the successor.
    function execute() external nonReentrant {
        address s = pending;
        if (s == address(0)) revert NothingPending();
        if (block.timestamp < proposedAt + DELAY) revert TooEarly();
        if (s.codehash != pendingCodeHash) revert CodeChanged();
        pending = address(0);
        _start(s);
        emit Executed(s, started);
    }

    /// @notice Ends the game into the built-in sunset successor at once: Apes auctioned, every wei to buybacks. The
    ///         owner. Cancels pending proposals; final (no later proposal of either kind).
    function sunset() external onlyOwner nonReentrant {
        pending = address(0);
        _start(sunsetter);
        emit Sunset(sunsetter);
    }

    /// @dev Trading fees follow the successor from here on: a pending fee-recipient proposal is cancelled and no new one
    ///      can be made (a later successor proposal, outside a sunset, is the only way to move them).
    function _start(address s) internal {
        pendingFeeRecipient = address(0);
        successor = s;
        if (!started) {
            started = true;
            game.retire();
        }
        hook.setFeeRecipient(s);
    }

    /// @notice Sends up to `max` Apes from custody to the successor, once the game has retired (settled and withdrawn
    ///         everything). Anyone; repeatable. Each Ape's record stays readable in the pool owner.
    function migrateApes(uint256 max) external nonReentrant returns (uint256 n) {
        address s = _ready();
        while (n < max) {
            (bool found,) = poolOwner.migrateApe(s);
            if (!found) break;
            ++n;
        }
        apesMigrated += n;
        emit ApesMigrated(s, n);
    }

    /// @notice Sends everything the vault holds to the successor, once the game has retired. Anyone; repeatable.
    function migrateCapital() external nonReentrant returns (uint256 amount) {
        address s = _ready();
        amount = vault.migrateCapital(s);
        capitalMigrated += amount;
        emit CapitalMigrated(s, amount);
    }

    // ------------------------------------------------------------------ trading fees

    /// @notice Proposes where trading fees go, a contract, executable after `DELAY`; its code is pinned. address(0)
    ///         cancels. It must accept ETH from the PoolManager in the middle of a swap, cheaply, or swaps revert.
    ///         Only while the game runs: once a migration or the sunset has started, fees follow the successor.
    function proposeFeeRecipient(address recipient) external onlyOwner {
        if (started) revert Started();
        bytes32 h;
        if (recipient != address(0)) {
            if (recipient.code.length == 0) revert NotAContract();
            h = recipient.codehash;
        }
        pendingFeeRecipient = recipient;
        pendingFeeCodeHash = h;
        feeProposedAt = block.timestamp;
        emit FeeRecipientProposed(recipient, h, recipient == address(0) ? 0 : block.timestamp + DELAY);
    }

    /// @notice Points trading fees at the pending recipient, at least `DELAY` after it was proposed and only if its
    ///         code is unchanged. Anyone.
    function executeFeeRecipient() external nonReentrant {
        address r = pendingFeeRecipient;
        if (r == address(0)) revert NothingPending();
        if (block.timestamp < feeProposedAt + DELAY) revert TooEarly();
        if (r.codehash != pendingFeeCodeHash) revert CodeChanged();
        pendingFeeRecipient = address(0);
        hook.setFeeRecipient(r);
        emit FeeRecipientExecuted(r);
    }

    // ------------------------------------------------------------------ views

    /// @notice When the pending migration becomes executable (0 if none).
    function executableAt() external view returns (uint256) {
        return pending == address(0) ? 0 : proposedAt + DELAY;
    }

    /// @notice When the pending fee recipient becomes executable (0 if none).
    function feeExecutableAt() external view returns (uint256) {
        return pendingFeeRecipient == address(0) ? 0 : feeProposedAt + DELAY;
    }

    function _ready() internal view returns (address) {
        if (!started) revert NotStarted();
        if (!game.retired()) revert NotSettled();
        return successor;
    }
}
