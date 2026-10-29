# Autonomous execution roadmap

The functional spec defines intended product behavior; this roadmap defines the order of proof and implementation. Follow phases without seeking approval at each boundary. Revise the design when technical evidence warrants doing so, rather than building elaborate workarounds.

## Phase 0: Bootstrap and architecture inventory
Inspect repository and tooling; initialize a pinned Foundry project; identify current Checks and FWA mainnet contracts; prepare a risk register and executable acceptance tests.
Exit: Local tests run, dependencies and interfaces are pinned, high risk experiments are specified.

## Phase 1: Prove the game lifecycle
Create a contract-owned FWA pool on an Ethereum mainnet fork; deposit real Checks; execute and settle draws including refunds and pending cases; verify surviving draw counts without keeper trust; withdraw, compose, and relist Checks; estimate gas for 64-single infinity; test repricing and stale price safety.
Exit: Reproducible fork evidence or a supported, simpler design revision. Mocks alone are insufficient.

## Phase 2: Prove custody and upgradeability
Threat-model owner, council, keeper, pricing, buyers, external integrations, and compromised permissions. Build minimal vault, controller and upgrade governance. Test direct extraction, approvals, unrestricted external calls, manipulated notional values, direct FWA acquire bypass, and malicious migration. Demonstrate migration to genuinely different approved FWA code with pending draws settled and user claims preserved.
Exit: Owner cannot unilaterally extract assets under the documented authority model; remaining trust assumptions are explicit. Do not equate testing with an audit.

## Phase 3: Simulate economics
Reproduce FWA selection, settlement and fee math. Include Shapes and Packs backing, VRF, keeper costs, inventory consumption, rising Checks prices, early jackpots, low and zero coin volume, notional decay, composition delays, ETH and BLACK buyouts. Optimize a simple, sustainable launch configuration and report sensitivities.
Exit: Reproducible simulation with concrete parameter proposals flagged for founder review.

## Phase 4: Build minimum complete protocol
Implement contracts for token, restricted treasury, acquisitions, survival, compositions, pricing and decay, direct sales, game integration, and governed upgrades. Build only essential keeper, indexer, and mobile-first UI. Run unit, integration, fuzz, invariant, and fork tests; remove redundant complexity.
Exit: Tested implementation with current technical documentation and independent security review findings.

## Phase 5: Launch readiness only
Reconcile contracts and dependencies, prepare audit package and mainnet rehearsal scripts, document residual risks, and prepare a concise grouped founder review. Seek independent legal review for paid chance-based game.
Exit: Audit-ready candidate. Do not deploy, spend funds, mint live token, or launch without explicit approval.

## Phase review
At each boundary ask: What outcome was proved? Which design assumption failed? Is the simpler solution to revise or drop a mechanic? What tests would falsify it? What decisions need founder review? Update spec, status, roadmap, and decisions together.
