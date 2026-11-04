// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solady/tokens/ERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IAdmin} from "../core/Governed.sol";
import {IVenuePolicy} from "../interfaces/IVenuePolicy.sol";
import {IMetadataRenderer} from "../interfaces/IMetadataRenderer.sol";
import {LibString} from "solady/utils/LibString.sol";
import {Base64} from "solady/utils/Base64.sol";

interface ICanonicalPool {
    function hook() external view returns (address);
    function poolKey() external view returns (PoolKey memory);
}

/// @title CollectionToken
/// @notice The ERC-20 coin of one collection game. The whole supply is minted once, in the constructor, to the
///         recipients the deploy script passes (at launch: all of it to ProtocolLiquidity). There is no mint
///         function, no fee and no upgrade path. Holders may burn their own tokens; the CollectionBurner burns every
///         token it buys. ERC-2612 permit is inherited from Solady.
///
///         Transfer restriction: the coin launches `restricted`, so it trades only in the canonical pool, where
///         every trade pays the hook's fee to the vault; a fee-free side pool cannot settle. While restricted, a
///         transfer between two holders reverts; a transfer to or from the PoolManager passes only against the net
///         coin the canonical pool's swaps in this transaction owe out (buys) or are owed (sells), and uses it up.
///         ProtocolLiquidity may send (the launch moves the supply into the pool). Mint and burn are never
///         restricted. The Admin owner keeps an allowlist (`setAllowed`, at most `MAX_ALLOWED` addresses, like FWA's
///         distributors): a transfer from or to an allowed address passes, except through the PoolManager, which
///         always takes the swap rule above and can never be allowed itself. The Admin owner's `unrestrict()` lifts
///         the rule for good; nothing turns it back on.
///
///         The policy is declared under URC-5 (`IVenuePolicy`): `Enforced` with the one canonical pool while
///         restricted, `Preferred` with no restriction after `unrestrict`; a refusal reverts `VenueNotAllowed`.
///
///         Metadata, as artcoins' coins (D86): `contractURI()` (ERC-7572) and `tokenURI()` return JSON with the name,
///         symbol, description and image, built here from the stored description and image URL, or by a metadata
///         renderer the Admin owner sets (`setMetadataRenderer`; zero: this built-in default). The Admin owner updates
///         the image and description; each change emits `ContractURIUpdated`. After a renounce all of it is frozen.
/// @dev The coin is not a claim on any ETH or NFT the protocol holds. Name and symbol are deploy-time values so the
///      same code serves every collection. Provenance: ripe0x/draw-shapes PR #9 `EngineToken` (MIT), without the
///      renderer and governance.
contract CollectionToken is ERC20, IVenuePolicy {
    using PoolIdLibrary for PoolKey;

    uint256 public immutable TOTAL_SUPPLY;
    /// @notice The shared Admin contract: its owner may `unrestrict`.
    IAdmin public immutable admin;
    /// @notice ProtocolLiquidity: the one sender the restriction allows, and the source of the canonical hook.
    address public immutable liquidity;
    address public immutable poolManager;
    /// @notice Whether transfers are limited to canonical swaps. Set at deployment; `unrestrict` clears it for good.
    bool public restricted = true;
    /// @notice The most addresses the allowlist may hold, so `externalVenues` can always return all of them.
    uint256 public constant MAX_ALLOWED = 50;
    /// @notice Addresses that may send or receive the coin while it is restricted (the Admin owner's, any time).
    mapping(address => bool) public isAllowed;
    address[] internal _allowed;

    /// @dev Transient, signed: the net coin the canonical pool's swaps in this transaction leave to cross the
    ///      PoolManager. Positive may leave it (bought coin taken), negative may enter it (sold coin settled). Buys and
    ///      sells that cancel inside one unlock leave nothing, so they cannot carry an unrelated transfer through it.
    uint256 private constant _SWAP_ALLOWANCE_SLOT = uint256(keccak256("CollectionToken.swapAllowance"));
    bytes32 internal immutable _nameHash;

    string internal _name;
    string internal _symbol;
    string internal _image;
    string internal _metadata;
    address internal _metadataRenderer;

    error SupplyMismatch();
    error ZeroAddress();
    error NotHook();
    error NotOwner();
    error NotRestricted();
    error CannotAllow();
    error InvalidRenderer();

    event Unrestricted();
    event AllowedSet(address indexed account, bool allowed);
    event UpdateImage(string image);
    event UpdateMetadata(string metadata);
    event MetadataRendererUpdated(address indexed renderer);
    /// @notice ERC-7572: the contract URI changed (indexers re-read it).
    event ContractURIUpdated();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory image_,
        string memory metadata_,
        uint256 totalSupply_,
        address[] memory recipients,
        uint256[] memory amounts,
        address admin_,
        address liquidity_,
        address poolManager_
    ) {
        if (recipients.length != amounts.length || totalSupply_ == 0) revert SupplyMismatch();
        if (admin_ == address(0) || liquidity_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        admin = IAdmin(admin_);
        liquidity = liquidity_;
        poolManager = poolManager_;
        emit VenueEnforcementChanged(VenueEnforcement.Enforced);
        emit CanonicalPoolsChanged();
        _name = name_;
        _symbol = symbol_;
        _image = image_;
        _metadata = metadata_;
        _nameHash = keccak256(bytes(name_));
        TOTAL_SUPPLY = totalSupply_;
        uint256 sum;
        for (uint256 i; i < recipients.length; ++i) {
            if (recipients[i] == address(0)) revert ZeroAddress();
            _mint(recipients[i], amounts[i]);
            sum += amounts[i];
        }
        if (sum != totalSupply_) revert SupplyMismatch();
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function _constantNameHash() internal view override returns (bytes32) {
        return _nameHash;
    }

    /// @notice The canonical hook records the coin side of a swap it just processed, from the trader's side (positive:
    ///         coin the trader may take out of the PoolManager; negative: coin the trader must settle into it), so that
    ///         settle or take passes the restriction for the rest of this transaction.
    /// @dev The hook is read from ProtocolLiquidity (wired once at deployment); the pool it serves admits only
    ///      ProtocolLiquidity's own pool (`CollectionHook.beforeInitialize`), so an allowance only ever follows a swap
    ///      in the canonical pool.
    function allowSwapTransfer(int256 coinDelta) external {
        if (msg.sender != ICanonicalPool(liquidity).hook()) revert NotHook();
        uint256 slot = _SWAP_ALLOWANCE_SLOT;
        assembly ("memory-safe") {
            tstore(slot, add(tload(slot), coinDelta))
        }
    }

    /// @notice Adds `account` to the allowlist or removes it. The Admin owner only. Neither the zero address nor the
    ///         PoolManager can be allowed (every transfer through the PoolManager keeps the swap rule).
    function setAllowed(address account, bool allowed) external {
        if (msg.sender != admin.owner()) revert NotOwner();
        if (account == address(0) || account == poolManager) revert CannotAllow();
        if (isAllowed[account] == allowed) return;
        isAllowed[account] = allowed;
        if (allowed) {
            if (_allowed.length == MAX_ALLOWED) revert CannotAllow();
            _allowed.push(account);
        } else {
            uint256 n = _allowed.length;
            for (uint256 i; i < n; ++i) {
                if (_allowed[i] == account) {
                    _allowed[i] = _allowed[n - 1];
                    _allowed.pop();
                    break;
                }
            }
        }
        emit AllowedSet(account, allowed);
        emit VenueStatusChanged(account, bytes32(0), true, allowed);
        emit VenueStatusChanged(account, bytes32(0), false, allowed);
        emit ExternalVenuesChanged();
    }

    /// @notice The allowlist, in no particular order.
    function allowedList() external view returns (address[] memory) {
        return _allowed;
    }

    // ------------------------------------------------------------------ metadata (ERC-7572, as artcoins)

    /// @notice Updates the image URL in the default contract URI. The Admin owner only.
    function updateImage(string calldata image_) external {
        if (msg.sender != admin.owner()) revert NotOwner();
        _image = image_;
        emit UpdateImage(image_);
        emit ContractURIUpdated();
    }

    /// @notice Updates the description in the default contract URI. The Admin owner only.
    function updateMetadata(string calldata metadata_) external {
        if (msg.sender != admin.owner()) revert NotOwner();
        _metadata = metadata_;
        emit UpdateMetadata(metadata_);
        emit ContractURIUpdated();
    }

    /// @notice Sets the metadata renderer that builds the contract URI; zero falls back to the built-in default. The
    ///         Admin owner only. A non-zero renderer must have code, so the URI never points at an account.
    function setMetadataRenderer(address renderer_) external {
        if (msg.sender != admin.owner()) revert NotOwner();
        if (renderer_ != address(0) && renderer_.code.length == 0) revert InvalidRenderer();
        _metadataRenderer = renderer_;
        emit MetadataRendererUpdated(renderer_);
        emit ContractURIUpdated();
    }

    /// @notice Contract-level metadata per ERC-7572.
    function contractURI() external view returns (string memory) {
        return _resolveURI();
    }

    /// @notice The coin's metadata (the same as `contractURI`).
    function tokenURI() external view returns (string memory) {
        return _resolveURI();
    }

    function imageUrl() external view returns (string memory) {
        return _image;
    }

    function metadata() external view returns (string memory) {
        return _metadata;
    }

    function metadataRenderer() external view returns (address) {
        return _metadataRenderer;
    }

    function _resolveURI() internal view returns (string memory) {
        if (_metadataRenderer != address(0)) return IMetadataRenderer(_metadataRenderer).contractURI(address(this));
        string memory json = string.concat(
            '{"name":"', LibString.escapeJSON(_name), '","symbol":"', LibString.escapeJSON(_symbol), '","description":"',
            LibString.escapeJSON(_metadata), '","image":"', LibString.escapeJSON(_image), '"}'
        );
        return string.concat("data:application/json;base64,", Base64.encode(bytes(json)));
    }

    /// @notice Lifts the transfer restriction for good. The Admin owner only; there is no way to restore it.
    function unrestrict() external {
        if (msg.sender != admin.owner()) revert NotOwner();
        if (!restricted) revert NotRestricted();
        restricted = false;
        emit Unrestricted();
        emit VenueEnforcementChanged(VenueEnforcement.Preferred);
        emit ExternalVenuesChanged();
    }

    // ------------------------------------------------------------------ URC-5 venue policy (declaration only)

    function venueEnforcement() external view returns (VenueEnforcement) {
        return restricted ? VenueEnforcement.Enforced : VenueEnforcement.Preferred;
    }

    /// @notice The one canonical pool: ETH / coin with the hook, as ProtocolLiquidity opens it (its hook is set at
    ///         deployment, before the market can open).
    function canonicalPools() external view returns (PoolKey[] memory keys) {
        keys = new PoolKey[](1);
        keys[0] = ICanonicalPool(liquidity).poolKey();
    }

    /// @notice While restricted, the PoolManager for the canonical pool and the allowlist, in either direction;
    ///         afterwards, any.
    function venueAllowed(address venue, bytes32 poolId, bool) external view returns (bool) {
        return !restricted || isAllowed[venue]
            || (venue == poolManager && poolId == PoolId.unwrap(ICanonicalPool(liquidity).poolKey().toId()));
    }

    /// @notice While restricted, both directions are, and the venues outside the v4 pool are the allowlist, both ways
    ///         (ProtocolLiquidity's exemption only lets it seed the pool once and is not a trading venue).
    function externalVenues()
        external
        view
        returns (bool inboundRestricted, bool outboundRestricted, ExternalVenue[] memory allowed)
    {
        uint256 n = _allowed.length;
        allowed = new ExternalVenue[](n);
        for (uint256 i; i < n; ++i) {
            allowed[i] = ExternalVenue(_allowed[i], true, true);
        }
        return (restricted, restricted, allowed);
    }

    function supportsInterface(bytes4 id) external pure returns (bool) {
        return id == 0x01ffc9a7 || id == type(IVenuePolicy).interfaceId; // ERC-165, URC-5
    }

    function _beforeTokenTransfer(address from, address to, uint256 amount) internal override {
        if (!restricted || from == address(0) || to == address(0) || from == liquidity) return;
        // the token cannot tell which v4 pool a PoolManager transfer is for, so it reports pool id 0 (URC-5); a transfer
        // that does not touch the PoolManager passes only to or from an allowed address, and one that does always
        // takes the swap rule, allowed or not, so the allowlist never opens another pool or an unswapped exit
        if (from != poolManager && to != poolManager) {
            if (isAllowed[from] || isAllowed[to]) return;
            revert VenueNotAllowed(to, bytes32(0), true);
        }
        uint256 slot = _SWAP_ALLOWANCE_SLOT;
        int256 a;
        assembly ("memory-safe") {
            a := tload(slot)
        }
        // amount <= total supply, far inside int256
        int256 m = int256(amount);
        if (from == poolManager ? a < m : -a < m) revert VenueNotAllowed(poolManager, bytes32(0), to == poolManager);
        a = from == poolManager ? a - m : a + m;
        assembly ("memory-safe") {
            tstore(slot, a)
        }
    }

    /// @notice Burns `amount` of the caller's tokens. Total supply only ever falls.
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /// @notice Burns `amount` of `from`'s tokens against the caller's allowance (the Checks desk burns what a player
    ///         pays for a composition choice or a coin buyout; a burn passes the transfer restriction).
    function burnFrom(address from, uint256 amount) external {
        _spendAllowance(from, msg.sender, amount);
        _burn(from, amount);
    }
}
