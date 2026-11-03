// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {CollectionToken} from "../src/token/CollectionToken.sol";
import {CollectionHook} from "../src/token/CollectionHook.sol";
import {ProtocolLiquidity} from "../src/token/ProtocolLiquidity.sol";
import {FundingVault} from "../src/core/FundingVault.sol";
import {CollectionPoolOwner} from "../src/core/CollectionPoolOwner.sol";
import {CollectionGame} from "../src/game/CollectionGame.sol";
import {CollectionBurner} from "../src/treasury/CollectionBurner.sol";
import {Admin} from "../src/core/Admin.sol";
import {MigrationAuthority} from "../src/migration/MigrationAuthority.sol";
import {Sunset} from "../src/migration/Sunset.sol";
import {Lens} from "../src/periphery/Lens.sol";
import {DrawRouter, IGameSync} from "../src/periphery/DrawRouter.sol";
import {SeaportAdapter} from "../src/periphery/SeaportAdapter.sol";
import {LayerTap} from "../src/periphery/LayerTap.sol";

interface IPacksView {
    function shapes() external view returns (address);
    function MIN_PACK_VALUE() external view returns (uint256);
    function admin() external view returns (address);
    function renderer() external view returns (address);
    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
}

interface IShapesUnit {
    function unit() external view returns (uint256);
}

/// @notice The one deployment routine, shared by the scripts and the fork tests so the tests exercise exactly what is
///         broadcast: the Ape Draw coin (token, liquidity, hook, burner), its game (vault, pool owner, game, Draw Packs,
///         the Seaport adapter) and the end-of-life contracts (MigrationAuthority, Sunset). One `Admin` contract names
///         the owner of every governed contract (two-step transfer, renounce; D57). `postflight` reads every
///         reference, permission and launch value back.
abstract contract DeploySystem {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Config {
        // administration
        address owner; // the one administrator (two-step transferable, renounceable)
        // external
        address collection; // the ERC-721 collection
        address shapes;
        address fwaFactory;
        address fwaImplementation;
        address poolManager;
        address seaport; // the marketplace the vault's one adapter fills orders on (address(0): no adapter)
        address create2Deployer; // the address whose CREATE2 deploys the hook (the deterministic proxy in scripts)
        bool create2Direct; // tests: the deploying contract itself runs CREATE2 (create2Deployer is that contract)
        // coin
        string name;
        string symbol;
        string coinImage; // the coin's image URL in its contract URI (may be empty; the owner may set it later, D86)
        string coinDescription; // the coin's description in its contract URI (may be empty; settable later, D86)
        uint256 supply;
        int24 startTick; // the opening price, coin per ETH (fixed in ProtocolLiquidity; the owner only opens the market)
        uint256 buyFeeBps;
        uint256 sellFeeBps;
        // board and pricing (game settings)
        uint256[] boardPattern; // repeated without end; the board grows as the collection NFTs need it
        uint256 initialBoardSize;
        uint256 listBatch;
        uint256 maxPerCall; // prizes one maintenance call lists, sized for EIP-7825's gas cap (D61)
        uint256 bookPerCall; // requests one sync or retireStep books, sized for the same cap
        uint256 markupBps;
        uint256 opsBps; // keeper allowance earned per capture
        CollectionGame.Settings settings;
        // keepers: paid by the game, gas plus a flat fee, within the allowance
        CollectionGame.KeeperParams keeper;
        uint256 openingAllowance; // keeper pay available before any capture (listing the opening board)
        // collection listings
        uint256 maxInFlight;
        CollectionPoolOwner.ListingParams listing;
        // acquisition: the vault's standing bid
        FundingVault.BidParams bid;
        uint256 refPrice; // the live floor at deploy
        uint256 firstThresholdBps; // the first activation threshold, of `refPrice` (later ones: `bid.thresholdBps`)
        uint256 overflowBps; // fee overflow share (D64)
        uint256 layerBps; // $LAYER share of each trading fee after the launch curve, taken by the hook (D90)
        address layerBurner; // artcoins' $LAYER burn router the LayerTap forwards to (address(0): none)
        // Draw Packs: a dedicated instance of lib/shape-packs (`ShapePacks`) for this game's Pack prizes
        string packsName;
        string packsSymbol;
        uint256 packMinUnits; // the Pack minimum, in Shapes units (2: a 0.02 ETH Pack)
        // buybacks
        uint256 milestoneBps; // share of each surplus locked in the burner's milestone reserve
        CollectionBurner.Cadence cadence; // buyback cadence (D64)
        CollectionBurner.Tiers tiers; // milestone release tiers (D64)
    }

    struct System {
        Admin admin;
        MigrationAuthority migration;
        ProtocolLiquidity liquidity;
        CollectionToken token;
        CollectionBurner burner;
        FundingVault vault;
        CollectionHook hook;
        CollectionPoolOwner poolOwner;
        CollectionGame game;
        Sunset sunset;
        SeaportAdapter adapter;
        Lens lens;
        DrawRouter drawRouter; // stateless player entry point (D53)
        address packs; // the dedicated Draw Packs instance
        address packRenderer;
        address layerTap; // collects the hook's $LAYER share for artcoins' burn router (address(0): none)
    }

    error DeployMismatch(string what);

    function _check(bool ok, string memory what) internal pure {
        if (!ok) revert DeployMismatch(what);
    }

    /// @dev Deploys and wires everything from `deployer` (the address whose CREATE nonce is used).
    function _deploySystem(Config memory c, address deployer) internal returns (System memory s) {
        _deployGovAndToken(c, s, deployer);
        _deployHolders(c, s);
        _deployGame(c, s);
        s.sunset = new Sunset(c.collection, address(s.burner), address(s.poolOwner), address(s.game));
        if (c.seaport != address(0)) s.adapter = new SeaportAdapter(c.seaport, address(s.vault));
        s.lens = new Lens();
        s.drawRouter = new DrawRouter(IGameSync(address(s.game)));
        _wire(c, s);
    }

    function _deployGovAndToken(Config memory c, System memory s, address deployer) internal {
        s.admin = new Admin(c.owner);
        address a = address(s.admin);
        s.migration = new MigrationAuthority(a);
        // The coin mints its whole supply to ProtocolLiquidity, which needs the coin's address: predict it.
        address predictedToken = VM.computeCreateAddress(deployer, VM.getNonce(deployer) + 1);
        s.liquidity = new ProtocolLiquidity(a, IPoolManager(c.poolManager), predictedToken, c.startTick);
        address[] memory to = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        (to[0], amounts[0]) = (address(s.liquidity), c.supply);
        s.token = new CollectionToken(
            c.name, c.symbol, c.coinImage, c.coinDescription, c.supply, to, amounts, a, address(s.liquidity), c.poolManager
        );
        _check(address(s.token) == predictedToken, "token address");
    }

    function _deployHolders(Config memory c, System memory s) internal {
        address a = address(s.admin);
        s.burner = new CollectionBurner(
            a, IPoolManager(c.poolManager), address(s.token), c.cadence, c.tiers, c.milestoneBps
        );
        s.vault = new FundingVault(
            a, c.poolManager, c.collection, address(s.burner), address(s.migration), c.bid, c.overflowBps, c.refPrice,
            c.firstThresholdBps
        );
        if (c.layerBurner != address(0)) s.layerTap = address(new LayerTap(c.layerBurner));
        s.hook = _deployHook(c, s);
        _deployPacks(c, s);
        s.poolOwner = _deployPoolOwner(c, s);
    }

    /// @dev A dedicated Draw Packs instance (and its renderer) wrapping the live Shapes token, with the configured
    ///      minimum. Created from the vendored artifacts (built with their own compiler settings); its admin, the owner,
    ///      reaches presentation only.
    function _deployPacks(Config memory c, System memory s) internal {
        s.packRenderer = VM.deployCode("out/ShapePackRenderer.sol/ShapePackRenderer.json", abi.encode(c.shapes));
        s.packs = VM.deployCode(
            "out/ShapePacks.sol/ShapePacks.json",
            abi.encode(c.shapes, s.packRenderer, c.owner, c.packsName, c.packsSymbol, c.packMinUnits)
        );
    }

    function _deployPoolOwner(Config memory c, System memory s) internal returns (CollectionPoolOwner) {
        return new CollectionPoolOwner(
            CollectionPoolOwner.Init({
                admin: address(s.admin),
                factory: c.fwaFactory,
                expectedImplementation: c.fwaImplementation,
                shapes: c.shapes,
                packs: s.packs,
                collection: c.collection,
                vault: address(s.vault),
                migrator: address(s.migration),
                listing: c.listing,
                maxInFlight: c.maxInFlight
            })
        );
    }

    function _deployGame(Config memory c, System memory s) internal {
        s.game = new CollectionGame(
            CollectionGame.Config({
                admin: address(s.admin),
                factory: c.fwaFactory,
                poolOwner: address(s.poolOwner),
                vault: address(s.vault),
                burner: address(s.burner),
                migrator: address(s.migration),
                pattern: c.boardPattern,
                initialBoardSize: c.initialBoardSize,
                listBatch: c.listBatch,
                maxPerCall: c.maxPerCall,
                bookPerCall: c.bookPerCall,
                markupBps: c.markupBps,
                opsBps: c.opsBps,
                keeper: c.keeper,
                openingAllowance: c.openingAllowance,
                settings: c.settings
            })
        );
    }

    /// @dev One-shot wiring. Surplus goes to the vault (its share while short of an Ape) and the burner; the burner
    ///      verifies collection wins from the pool owner's FWA records. The collection, Shapes and Draw Packs are
    ///      recorded as the protocol's own NFTs, which no owner sweep may move (D62).
    function _wire(Config memory c, System memory s) internal {
        s.liquidity.wire(address(s.hook), address(s.poolOwner));
        s.burner.wire(address(s.hook), address(s.game), address(s.poolOwner));
        s.vault.wire(address(s.game), address(s.poolOwner), address(s.adapter));
        s.poolOwner.wire(address(s.game), _systemContracts(s));
        s.migration.wire(address(s.game), address(s.poolOwner), address(s.vault), address(s.hook), address(s.sunset));
        address[] memory own = new address[](3);
        (own[0], own[1], own[2]) = (c.collection, c.shapes, s.packs);
        s.admin.protect(own);
    }

    function _deployHook(Config memory c, System memory s) internal returns (CollectionHook hook) {
        bytes memory initCode = abi.encodePacked(type(CollectionHook).creationCode, _hookArgs(c, s));
        bytes32 initHash = keccak256(initCode);
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        bytes32 salt;
        address predicted;
        for (uint256 i; i < 400_000; ++i) {
            salt = bytes32(i);
            // plain keccak, not the cheatcode: the cheatcode in a loop stalls `forge script` on a fork
            predicted = address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), c.create2Deployer, salt, initHash)))));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK == flags && predicted.code.length == 0) break;
        }
        address deployed = _create2(salt, initCode, c.create2Deployer, c.create2Direct);
        _check(deployed == predicted, "hook address");
        hook = CollectionHook(deployed);
    }

    /// @dev CREATE2 from the deploying contract itself (tests), else through the deterministic deployment proxy
    ///      (`create2Deployer`, scripts), which takes `salt ++ initCode`.
    function _create2(bytes32 salt, bytes memory initCode, address factory, bool direct)
        internal
        returns (address deployed)
    {
        if (direct) {
            assembly ("memory-safe") {
                deployed := create2(0, add(initCode, 0x20), mload(initCode), salt)
            }
        } else {
            (bool ok, bytes memory ret) = factory.call(abi.encodePacked(salt, initCode));
            _check(ok && ret.length == 20, "create2 proxy");
            deployed = address(bytes20(ret));
        }
    }

    function _hookArgs(Config memory c, System memory s) internal pure returns (bytes memory) {
        return abi.encode(
            IPoolManager(c.poolManager),
            address(s.admin),
            address(s.token),
            address(s.liquidity),
            address(s.migration),
            address(s.vault),
            address(s.burner),
            c.buyFeeBps,
            c.sellFeeBps,
            s.layerTap,
            s.layerTap == address(0) ? 0 : c.layerBps
        );
    }

    // ------------------------------------------------------------------ postflight

    /// @notice Reads back every reference, permission and launch value; reverts `DeployMismatch` on any difference.
    function postflight(Config memory c, System memory s, address deployer) public view {
        // administration: one Admin naming the owner, read by every governed contract; no deployer power left
        _check(s.admin.owner() == c.owner && s.admin.pendingOwner() == address(0), "owner");
        address[7] memory governed = [
            address(s.liquidity), address(s.burner), address(s.vault), address(s.hook), address(s.poolOwner),
            address(s.game), address(s.migration)
        ];
        for (uint256 i; i < governed.length; ++i) {
            IGovernedView g = IGovernedView(governed[i]);
            _check(g.admin() == address(s.admin), "admin");
            _check(g.deployer() == address(0), "deployer power left");
        }
        // end of life: the MigrationAuthority (72 hours' notice, code pinned) and the sunset successor
        MigrationAuthority m = s.migration;
        _check(m.DELAY() == 72 hours && m.pending() == address(0) && !m.started(), "migration state");
        _check(m.pendingFeeRecipient() == address(0) && m.sunsetter() == address(s.sunset), "migration fee and sunset");
        _check(address(m.game()) == address(s.game) && address(m.poolOwner()) == address(s.poolOwner), "migration refs");
        _check(address(m.vault()) == address(s.vault) && address(m.hook()) == address(s.hook), "migration refs 2");
        _check(s.game.migrator() == address(m) && s.poolOwner.migrator() == address(m), "migrators");
        _check(s.vault.migrator() == address(m) && s.hook.migrator() == address(m), "migrators 2");
        _check(s.sunset.burner() == address(s.burner) && s.sunset.collection() == c.collection, "sunset routes");
        _check(address(s.sunset.poolOwner()) == address(s.poolOwner) && address(s.sunset.game()) == address(s.game), "sunset refs");
        // coin: fixed supply, all of it in ProtocolLiquidity until launch, none with the deployer
        // fixed at deploy; only burns (launch dust, buybacks, holders) can lower it afterwards
        _check(s.token.TOTAL_SUPPLY() == c.supply && s.token.totalSupply() <= c.supply, "supply");
        _check(
            s.token.balanceOf(address(s.liquidity)) == c.supply || s.liquidity.launched(), "liquidity holds supply"
        );
        _check(s.token.balanceOf(deployer) == 0, "deployer coins");
        _check(s.token.decimals() == 18, "decimals");
        // the transfer allowlist starts empty (the owner adds to it afterwards, D84)
        _check(s.token.restricted() && s.token.allowedList().length == 0, "coin allowlist");
        // hook: fees, caps, schedule, routes
        _check(s.hook.token() == address(s.token) && s.hook.launcher() == address(s.liquidity), "hook refs");
        _check(s.liquidity.hook() == address(s.hook) && s.liquidity.poolOwner() == address(s.poolOwner), "liquidity refs");
        // trading fees go to the vault. Postflight reads a deployment back (the migration checks above already refuse a
        // fee proposal or a started migration or sunset), so no other recipient is valid here (D88)
        _check(s.hook.feeRecipient() == address(s.vault), "fee route");
        _check(s.hook.buyFeeBps() == c.buyFeeBps && s.hook.sellFeeBps() == c.sellFeeBps, "fees");
        _check(s.hook.MAX_FEE_BPS() == 1_000, "fee cap");
        _check(s.hook.exempt(address(s.burner)) && !s.hook.exempt(address(s.liquidity)), "exempt set");
        _check(s.hook.LAUNCH_FEE_BPS() == 6_900 && s.hook.LAUNCH_DECAY_BPS_PER_MINUTE() == 100, "opening curve");
        _check(s.hook.launchedAt() == 0 || s.liquidity.launched(), "launch state");
        _check(s.liquidity.hook() == address(s.hook) && s.liquidity.token() == address(s.token), "liquidity refs");
        // the configured tick within sense: an opening value of the whole supply between about 1 and 1,000 ETH at 1B
        // coins (1.0001^tick coins per ETH), so a changed config cannot open the pool at a giveaway price
        _check(c.startTick >= 138_000 && c.startTick <= 208_000, "opening tick range");
        _check(s.liquidity.startTick() == c.startTick, "opening tick");
        _check(
            address(s.token.admin()) == address(s.admin) && s.token.liquidity() == address(s.liquidity)
                && s.token.poolManager() == c.poolManager && (s.token.restricted() || s.liquidity.launched()),
            "coin restriction"
        );
        // burner: the surplus sink, its milestone reserve verified from the pool owner's FWA records
        _check(s.burner.hook() == address(s.hook) && s.burner.token() == address(s.token), "burner refs");
        _check(address(s.burner.game()) == address(s.game) && s.burner.poolOwner() == address(s.poolOwner), "burner refs 2");
        _check(s.burner.milestoneBps() == c.milestoneBps, "milestone share");
        _check(keccak256(abi.encode(s.burner.cadence())) == keccak256(abi.encode(c.cadence)), "buyback cadence");
        _check(keccak256(abi.encode(s.burner.tiers())) == keccak256(abi.encode(c.tiers)), "buyback tiers");
        // vault and custody
        _check(s.vault.collection() == c.collection, "vault collection");
        _check(s.vault.poolManager() == c.poolManager && s.vault.burner() == address(s.burner), "vault refs");
        _check(address(s.vault.game()) == address(s.game) && address(s.vault.poolOwner()) == address(s.poolOwner), "vault wiring");
        _check(s.vault.adapter() == address(s.adapter), "adapter");
        if (address(s.adapter) != address(0)) {
            _check(address(s.adapter.seaport()) == c.seaport && s.adapter.vault() == address(s.vault), "adapter refs");
        }
        FundingVault.BidParams memory b = s.vault.bidParams();
        // the reference price follows every purchase: it matches the configured one until the first
        _check(
            (s.vault.lastPrice() == c.refPrice && s.vault.referencePrice() == c.refPrice) || s.vault.acquisitionCount() != 0,
            "bid reference"
        );
        _check(b.thresholdBps == c.bid.thresholdBps && b.maxPrice == c.bid.maxPrice, "bid");
        _check(b.maxSweepWei == c.bid.maxSweepWei && b.minBlocksBetweenSweeps == c.bid.minBlocksBetweenSweeps, "bid 2");
        _check(
            b.ceilingBps == c.bid.ceilingBps && b.slowSweepWei == c.bid.slowSweepWei && b.maxDropBps == c.bid.maxDropBps,
            "bid ceiling"
        );
        _check(s.vault.overflowBps() == c.overflowBps, "fee overflow");
        // the $LAYER share: the hook pays it to a LayerTap that forwards only to the configured router (D90)
        _check(
            s.hook.layerTap() == s.layerTap
                && (c.layerBurner == address(0)
                    ? s.layerTap == address(0) && s.hook.layerBps() == 0
                    : s.hook.layerBps() == c.layerBps && LayerTap(payable(s.layerTap)).router() == c.layerBurner
                        && LayerTap(payable(s.layerTap)).layerToken() == ILayerBurnerView(c.layerBurner).layerToken()),
            "layer share"
        );
        _check(
            s.vault.activationThreshold() == c.refPrice * c.firstThresholdBps / 10_000 || s.vault.acquisitionCount() != 0,
            "activation threshold"
        );
        _check(s.poolOwner.collection() == c.collection && s.poolOwner.shapes() == c.shapes, "pool owner collection");
        _check(s.poolOwner.vault() == address(s.vault) && s.poolOwner.game() == address(s.game), "pool owner wiring");
        _check(address(s.poolOwner.factory()) == c.fwaFactory, "factory");
        _check(s.poolOwner.expectedImplementation() == c.fwaImplementation, "fwa implementation");
        CollectionPoolOwner.ListingParams memory lp = s.poolOwner.listingParams();
        _check(keccak256(abi.encode(lp)) == keccak256(abi.encode(c.listing)), "listing params");
        _check(s.poolOwner.maxInFlight() == c.maxInFlight, "in-flight bound");
        // game
        _check(address(s.game.poolOwner()) == address(s.poolOwner) && address(s.game.vault()) == address(s.vault), "game refs");
        _check(s.game.burner() == address(s.burner) && address(s.game.factory()) == c.fwaFactory, "game routes");
        // the whole launch board, until activation (the owner may set another pattern later)
        if (!s.game.activated()) {
            _check(s.game.patternLength() == c.boardPattern.length, "pattern");
            for (uint256 i; i < c.boardPattern.length; ++i) {
                _check(s.game.rowAt(i) == c.boardPattern[i], "pattern row");
            }
        }
        _check(s.game.markupBps() == c.markupBps && s.game.opsBps() == c.opsBps, "pricing");
        _check(
            s.game.listBatch() == c.listBatch && s.game.maxPerCall() == c.maxPerCall && s.game.bookPerCall() == c.bookPerCall,
            "board params"
        );
        {
            (uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 a4, uint256 a5, uint256 a6, uint256 a7) =
                s.game.settings();
            _check(
                keccak256(abi.encode(a0, a1, a2, a3, a4, a5, a6, a7)) == keccak256(abi.encode(c.settings)), "game settings"
            );
            // the opening keeper allowance, until keepers start drawing on it
            _check(
                s.game.keeperAllowance() == c.openingAllowance || s.game.keeperPaid() != 0 || s.game.activated(),
                "opening allowance"
            );
        }
        CollectionGame.KeeperParams memory kp = s.game.keeperParams();
        _check(keccak256(abi.encode(kp)) == keccak256(abi.encode(c.keeper)), "keeper params");
        // the player entry point serves this game only
        _check(address(s.drawRouter.game()) == address(s.game), "draw router game");
        // the dedicated Draw Packs instance: wraps the live Shapes, the configured minimum, presentation admin only
        _check(s.poolOwner.packs() == s.packs && IPacksView(s.packs).shapes() == c.shapes, "packs");
        _check(IPacksView(s.packs).MIN_PACK_VALUE() == c.packMinUnits * IShapesUnit(c.shapes).unit(), "pack minimum");
        _check(IPacksView(s.packs).admin() == c.owner, "packs admin");
        _check(s.game.boardSize() == c.initialBoardSize || s.game.activated(), "board");
        // FWA pool, once created: owned by the pool owner forever, which is also its purchase operator, and able to
        // deliver every prize kind from the pool owner's custody
        address fwaPool = address(s.poolOwner.pool());
        if (fwaPool != address(0)) {
            _check(IOwnedView(fwaPool).owner() == address(s.poolOwner), "fwa pool owner");
            _check(IOwnedView(fwaPool).purchaseOperator() == address(s.poolOwner), "fwa purchase operator");
            address po = address(s.poolOwner);
            _check(
                IApprovalView(c.collection).isApprovedForAll(po, fwaPool) && IApprovalView(c.shapes).isApprovedForAll(po, fwaPool)
                    && IApprovalView(s.packs).isApprovedForAll(po, fwaPool),
                "fwa approvals"
            );
        }
        _postflightIdentity(c, s);
        // the protocol's own NFTs: never swept, and the list is closed
        _check(s.admin.isProtected(c.collection) && s.admin.isProtected(c.shapes), "protected collection");
        _check(s.admin.isProtected(s.packs) && s.admin.deployer() == address(0), "protected packs");
    }

    /// @dev Names, presentation and the pool owner's purchaser exclusions (split out of `postflight` for stack depth).
    function _postflightIdentity(Config memory c, System memory s) internal view {
        _check(_eq(s.token.name(), c.name) && _eq(s.token.symbol(), c.symbol), "coin identity");
        _check(
            _eq(s.token.imageUrl(), c.coinImage) && _eq(s.token.metadata(), c.coinDescription)
                && s.token.metadataRenderer() == address(0),
            "coin metadata"
        );
        IPacksView p = IPacksView(s.packs);
        _check(_eq(p.name(), c.packsName) && _eq(p.symbol(), c.packsSymbol), "packs identity");
        _check(p.renderer() == s.packRenderer && IPacksView(s.packRenderer).shapes() == c.shapes, "packs renderer");
        address[] memory sys = _systemContracts(s);
        for (uint256 i; i < sys.length; ++i) {
            _check(s.poolOwner.isSystem(sys[i]), "system purchaser");
        }
    }

    /// @dev Every contract the deploy creates that is not already refused as a draw's purchaser (round 4 G3), the
    ///      LayerTap included when there is one.
    function _systemContracts(System memory s) internal pure returns (address[] memory sys) {
        sys = new address[](s.layerTap == address(0) ? 10 : 11);
        (sys[0], sys[1], sys[2], sys[3], sys[4]) =
            (address(s.burner), address(s.hook), address(s.liquidity), address(s.token), address(s.admin));
        (sys[5], sys[6], sys[7], sys[8], sys[9]) =
            (address(s.sunset), address(s.adapter), address(s.lens), address(s.drawRouter), s.packRenderer);
        if (s.layerTap != address(0)) sys[10] = s.layerTap;
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}

interface ILayerBurnerView {
    function layerToken() external view returns (address);
}

interface IApprovalView {
    function isApprovedForAll(address owner, address operator) external view returns (bool);
}

interface IOwnedView {
    function owner() external view returns (address);
    function purchaseOperator() external view returns (address);
}

interface IGovernedView {
    function admin() external view returns (address);
    function deployer() external view returns (address);
}
