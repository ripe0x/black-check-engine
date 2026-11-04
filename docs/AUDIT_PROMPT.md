# Audit prompt: Checks Survival Protocol (rebased on collection-games)

Paste everything below the line into a fresh agent session that has this repository checked out
(`ripe0x/black-check-engine`, branch `claude/wizardly-shannon-440owk`), Foundry, Slither and outbound HTTPS. Nothing in
this file describes the code's design, its known issues or any earlier review; that is deliberate. Adapted from
ripe0x/collection-games `docs/AUDIT_PROMPT.md` (409ca75) for this repository.

---

Audit for high-impact ways an adversary could take assets, acquire authority, corrupt entitlements, or force
economically harmful state.

This is a fresh discovery run. Do not read prior audits, incident reports, exploit descriptions, previous agent
outputs, or files produced by earlier audit sessions. Work from deployed code and primary onchain evidence. Use
https://mainnet.gateway.tenderly.co for every Ethereum mainnet RPC call and Foundry fork. Do not broadcast
transactions.

First pin a block number and hash. Establish the deployed runtime bytecode, verified source, exact compiler settings,
source-to-runtime match, proxy status, and dependency relationships. Disclose every mismatch or uncertainty.

Before judging code checks, describe the system's purpose and the rights of the protocol, users, and interacting
contracts. Inventory assets it holds or can move, approvals and caller authority it may possess, and outcomes that
must never occur.

Compile the pinned source. Use Slither or an equivalent analyzer to enumerate entry points, external calls, state
writes, and call relationships. Reconcile the output manually with the source and ABI, including dynamic calls and
callbacks. Map sequences across functions and transactions. For each consequential path, identify attacker-controlled
inputs, identities, counterparties, prior state, ordering, and return or callback behavior.

Challenge each check as a claim: can execution pass it while violating an intended right? Search across distinct
assets and identities, boundary values, hostile counterparties, nested calls, and material economic states. Execute
the strongest counterexamples in Foundry against the pinned code or fork. Each cited test must show it reached the
relevant path and checks and must assert the harmed asset or right. Use fuzzing where the input or state space
warrants it; inspect its actual output. A reverted attempt excludes only its tested setup and sequence.

Maintain a working path ledger. Give every consequential path one of these dispositions: demonstrated violation;
supported exclusion within an explicit bounded model; attempted with exact search limits; or open. For each open path,
record the next decisive check and whether it is feasible now.

CRITICAL STOP RULE: Do not end the turn because a report exists, tests pass, a structural gate fails, or one tool is
rate limited. Treat gate failures and open paths as a work queue. Continue every feasible consequential check, using
another permitted method when one method fails. Before sending a final answer, inspect the ledger: if any
consequential path has a feasible next check, perform it. Preserve progress through context compaction. End with a
bounded report only when no meaningful next check is feasible with the available access and budget. If external
access or user input is genuinely required, state the exact blocker, continue independent work, and ask one specific
blocking question.

Report confirmed findings with executable reproduction, prerequisites, impact, and exact affected runtime revision.
Separately report unresolved paths, integrations, tool failures, and the limits of every negative conclusion. Do not
claim the contract is safe, the audit exhaustive, or a failed gate passed.

## How these directions apply to this target

**The system is not deployed.** No in-scope contract exists on mainnet yet. Apply the directions as follows:

1. **Pin the source.** Record `git rev-parse HEAD` of the checked-out branch and the commit of every submodule
   (`git submodule status`). That commit is the audited revision; every finding names it.
2. **Pin the chain.** Pick a recent mainnet block, record its number and hash from the Tenderly gateway, and use it for
   every fork (`forge test --fork-url https://mainnet.gateway.tenderly.co --fork-block-number <N>`, or an anvil fork of
   the same URL and block). If the gateway rate-limits, back off and retry, or reduce parallelism; do not switch RPC
   providers and do not stop.
3. **"Deployed runtime bytecode" for the in-scope system** means the code produced by deploying it on that fork with
   the repository's own deployment script (`script/DeploySystem.sol`, with the values in `script/LaunchConfig.sol` and
   `script/env/mainnet.env`; `script/Deploy.s.sol` is the entry point). Deploy it yourself on the fork, read back each
   contract's runtime code, and match it to your own compilation of the pinned source with the exact settings in
   `foundry.toml` (solc 0.8.28, cancun, optimizer 200 runs, via-IR, no CBOR metadata; `lib/shape-packs/src/**` is
   compiled with via-IR and 20 runs; a clean build takes about 35 minutes). Account for immutables. Record the deployer, owner and every address the script
   wires, and every role, approval and one-time wiring call it makes. Where the deployment needs a value the script
   marks as an owner input (for example the reference price), state the value you used and test the boundaries.
4. **Onchain dependencies.** For each external contract the system calls or holds assets of, establish at the pinned
   block: runtime bytecode, verified source if you can obtain it, compiler settings, proxy or clone status and current
   implementation, admin or owner, and anything that can change its behaviour later. At least: the FWA V2 factory
   `0xF5A3A153164791AB579C3d9ba5DBECf7cDfd300c` and the implementation it clones `0xEaa4d032908A9734a2c7939c0D211c35ad51eb31`
   (and the VRF service they use), the FWA token `0xa0Df17B5aC76ABaBA36E1450E2cbCd18A620C845` and its pool and hook,
   Shapes `0x6fE9193276bF7aBCbEE44AB7aFd717d637D6FAf0`, Checks Originals `0x036721e5A769Cc48B3189EFbb9ccE4471E8A48B1`
   and Checks Editions `0x34eEBEE6942d8Def3c125458D1a86e0A897fd6f9`, FWA's community pool factory
   `0x8919814D825a5Af238cC04DE06b1C18c9eaA477C` (a possible migration target), the Uniswap v4
   PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` and Seaport 1.6 `0x0000000000000068F116a894984e2DB1123eB395`.
   Find any other dependency from the code and the fork trace. Treat the vendored source under `lib/` as a claim to be
   matched against the onchain code, not as evidence of it.
5. **Scope.** In scope: everything under `src/`, the Draw Packs contract under `lib/shape-packs/src/` (deployed by
   this system as first-party code), and the deployment wiring in `script/`. External dependencies are out of scope for
   findings about their own internals but in scope as counterparties: model hostile or unexpected behaviour from any of
   them that is possible at the pinned block or could become possible through their own upgrade or admin paths.
6. **Privileged identities.** The system has an owner, a council (an OpenZeppelin TimelockController the deployment
   creates, with a proposer Safe and a canceller guardian), and other permissioned callers. Include paths where any
   identity, the owner included, gets authority, assets or effects beyond what the code grants it, and paths where an
   unprivileged caller obtains a privileged effect. Report harms that need the owner's key, and harms that need the council, separately and label them as such; the owner alone must not be able to move custody, redirect value or change what a Check is worth.
7. **What not to read.** Everything outside the material listed above is a previous agent output for this run. Do
   not open: `docs/` (this file excepted), `sim/`, `test/`, `keeper/`, `site/`, `deployments/`, any `README` or other
   Markdown file in the repository (CLAUDE.md included), `docs/receipts/`, `docs/review/`, and git commit messages or history beyond the
   hashes in step 1. Do not open ripe0x/collection-games (or any local copy of it): it is the base this code was built from, and its audit outputs are earlier audits of related code. The NatSpec and comments inside `src/` and `script/` are part of the code; treat what they assert
   as claims to test, not as evidence.
8. **Where to work.** Write your harness, tests and fuzz campaigns under a new `audit/` directory (its own
   `foundry.toml` profile if you need one); do not modify `src/`, `script/` or `lib/`. Keep the path ledger in
   `audit/LEDGER.md` and update it as you go, so progress survives context compaction. Write the final report to
   `audit/REPORT.md`, with each finding's reproduction command and the commit and block it ran against. Do not push or
   open a pull request unless asked.
