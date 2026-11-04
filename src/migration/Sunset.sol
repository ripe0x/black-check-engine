// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

interface ISunsetPoolOwner {
    function nfts(uint256 tokenId)
        external
        view
        returns (uint128 refCost, uint128 cashCost, uint8 tier, uint8 source, uint8 state, uint32 carried);
    function scheduleOf(uint8 tier) external view returns (uint256);
}

interface ISunsetGame {
    function retired() external view returns (bool);
}

interface IERC721Sunset {
    function ownerOf(uint256 tokenId) external view returns (address);
    function transferFrom(address from, address to, uint256 tokenId) external;
}

/// @title Sunset
/// @notice The built-in end of the game: the successor `MigrationAuthority.sunset` hands everything to, at once. It has
///         no owner and one outflow for ETH: the CollectionBurner, which buys the coin and burns it. Every Ape the game
///         held is sold in a public Dutch auction, from 150% of its recorded cost down to 25% over 30 days (then 25%),
///         and every wei paid for it goes to the burner in the same call. The vault's capital and any trading fees
///         that reach it go to the burner too (`flush`, anyone).
contract Sunset is ReentrancyGuard {
    uint256 public constant AUCTION_DURATION = 30 days;
    uint256 internal constant BPS = 10_000;

    address public immutable collection;
    address public immutable burner;
    ISunsetPoolOwner public immutable poolOwner;
    ISunsetGame public immutable game;

    /// @notice When the auction clock started (0 until the game has retired and someone starts it).
    uint256 public startedAt;
    uint256 public auctionProceeds;
    uint256 public flushed;

    event AuctionStarted(uint256 at);
    event AuctionSale(uint256 indexed tokenId, address indexed buyer, uint256 price);
    event Flushed(uint256 amount);

    error NotRetired();
    error NotHeld();
    error Underpaid();

    constructor(address collection_, address burner_, address poolOwner_, address game_) {
        collection = collection_;
        burner = burner_;
        poolOwner = ISunsetPoolOwner(poolOwner_);
        game = ISunsetGame(game_);
    }

    /// @notice Capital, trading fees and anything else sent here: held until `flush` sends it to the burner.
    receive() external payable {}

    /// @notice Starts the auction clock once the game has retired. Anyone; once.
    function start() public {
        if (!game.retired()) revert NotRetired();
        if (startedAt == 0) {
            startedAt = block.timestamp;
            emit AuctionStarted(block.timestamp);
        }
    }

    /// @notice Auction price of a Check held here: 150% of its value falling linearly to 25% over 30 days, then 25%.
    ///         Before the clock starts, 150%. Its value is the higher of its recorded cost (composition sums its
    ///         inputs') and its tier's schedule price (D015; review C-1: a composite or Black Check is never sold at an
    ///         80-Check's price).
    function auctionPrice(uint256 tokenId) public view returns (uint256) {
        (uint128 cost,, uint8 tier,,,) = poolOwner.nfts(tokenId);
        uint256 sched = poolOwner.scheduleOf(tier);
        uint256 ref = cost > sched ? cost : sched;
        uint256 t = startedAt == 0 ? 0 : block.timestamp - startedAt;
        if (t > AUCTION_DURATION) t = AUCTION_DURATION;
        return uint256(ref) * (15_000 - 12_500 * t / AUCTION_DURATION) / BPS;
    }

    /// @notice Buys an Ape held here at its auction price, which goes to the burner in the same call; anything sent
    ///         above it is returned.
    function buy(uint256 tokenId) external payable nonReentrant {
        if (startedAt == 0) start();
        if (IERC721Sunset(collection).ownerOf(tokenId) != address(this)) revert NotHeld();
        uint256 price = auctionPrice(tokenId);
        if (msg.value < price) revert Underpaid();
        auctionProceeds += price;
        IERC721Sunset(collection).transferFrom(address(this), msg.sender, tokenId);
        SafeTransferLib.forceSafeTransferETH(burner, price);
        if (msg.value > price) SafeTransferLib.safeTransferETH(msg.sender, msg.value - price);
        emit AuctionSale(tokenId, msg.sender, price);
    }

    /// @notice Sends everything held here to the burner, and starts the auction clock if the game has retired and nobody
    ///         has yet (the keeper bot flushes). Anyone.
    function flush() external nonReentrant returns (uint256 amount) {
        if (startedAt == 0 && game.retired()) start();
        amount = address(this).balance;
        if (amount == 0) return 0;
        flushed += amount;
        SafeTransferLib.forceSafeTransferETH(burner, amount);
        emit Flushed(amount);
    }
}
