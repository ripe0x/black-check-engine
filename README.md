# Checks Survival Protocol (working title)

An autonomous game for Checks on Ethereum, with its own fixed-supply coin (name and ticker unresolved; placeholders are
refused by the deployment). Checks sit in an FWA V2 pool as prizes beside ETH-backed Shapes and Draw Packs; players pay
ETH to draw. A Check that survives draws becomes cheaper to win and, after enough of them, eligible for canonical
composition up the tiers to a Black Check. Trading fees on the coin buy Checks; game surplus buys and burns the coin when
a Check is won. Built on ripe0x/collection-games (409ca75); the first implementation is archived at tag `rc2`.

**Not audited. Not deployed. Launch requires a satisfactory audit, legal review, a coin name, and council keys.**

Start with docs/STATUS.md (where the work stands and how to resume), docs/REBASE_PLAN.md (the plan and progress),
docs/ARCHITECTURE.md and docs/ADMIN.md (the system and who can do what), docs/DECISIONS.md (every decision, the review
queue first). Tracking PR: ripe0x/black-check-engine#1. Provenance: NOTICE.md.

```
src/core        Admin (owner + council), Governed, FundingVault (live bid), CollectionPoolOwner (Checks custody,
                survival, decay, the FWA pool)
src/checks      ChecksDesk (composition, Black Check formation, buyouts)
src/game        CollectionGame (the ledger, board, keeper pay)
src/token       CollectionToken, CollectionHook, ProtocolLiquidity
src/treasury    CollectionBurner
src/migration   MigrationAuthority, Sunset
src/periphery   DrawRouter, Lens, SeaportAdapter, FwaFeeRoutes, LayerTap
script/         DeploySystem (deploy + postflight, council timelock), LaunchConfig, Deploy, rehearse-anvil.sh
test/           fork (block 26,337,000), invariant, scenario, unit
sim/            checks_market.py (D016) and collection-games' models
keeper/         permissionless keeper (Node, viem), incl. the free deterministic composition
site/           player site (Next.js static export; not published)
docs/base/      collection-games' documents, for reference
```

## Build and test

```
git submodule update --init --recursive
forge build                      # via-IR (slow: about 20-30 minutes from clean)
anvil --fork-url https://mainnet.gateway.tenderly.co --fork-block-number 26337000 --port 8546 &
MAINNET_RPC_URL=http://127.0.0.1:8546 forge test --threads 3 --no-match-path 'test/scenario/Throughput.t.sol'
FOUNDRY_PROFILE=fast forge test ...   # iteration only (no IR; the EIP-170 size test fails there by design)
python3 sim/checks_market.py
cd keeper && npm ci && node --test test/policy.test.mjs
cd site && npm ci && npm run abi && npm run typecheck && npm run build
FORK_URL=https://mainnet.gateway.tenderly.co script/rehearse-anvil.sh
```

`CLAUDE.md` holds the operating instructions and the founder's invariants.
