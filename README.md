# Checks Survival Protocol: Claude Code autonomous project starter

This is a project working package. It includes the current design baseline and persistent instructions for an agent to build, test, critique, and refine the protocol over multiple sessions without repeatedly asking the founder for routine choices.

## Start in Claude Code

1. Clone this repository with `git clone https://github.com/ripe0x/black-check-engine.git`.
2. Open a terminal in the cloned repository.
3. Open Claude Code in this directory. Use Auto permission mode where supported. Do not use permission bypass, do not provide wallet keys, and do not grant mainnet transaction authority.
4. Paste the contents of `START_PROMPT.md` as your first message.
5. Let the agent follow `docs/ROADMAP.md`, making local commits and updating `docs/STATUS.md` as it progresses.
6. At convenient intervals, review the top entries in `docs/DECISIONS.md`, then respond with a single grouped message. The agent should not need constant replies.

When a Claude Code session ends, reopen the same repository and say: `Read CLAUDE.md and docs/STATUS.md, then continue the next safe task. Keep logging material decisions for later review.`

## File priorities

1. `CLAUDE.md`: how the agent should operate and which founder decisions are settled.
2. `docs/FUNCTIONAL_SPEC.md`: the latest intended product mechanics and design baseline.
3. `docs/ROADMAP.md`: phases and acceptance criteria.
4. `docs/DECISIONS.md`: review queue and design change record.
5. `docs/STATUS.md`: verified progress and resumability across sessions.
6. `reference/`: earlier research and an outdated controller experiment. Informational only. Do not use it as proof of production security.

The named coin and final ticker remain unresolved. The agent should use an internal placeholder and log the branding decision for a later user review rather than blocking implementation.

## Review the work rather than supervising each step

Ask the agent for: `Show the top decisions requiring my review, each with your recommendation, the tradeoff, and whether anything is blocked.`

You can approve or redirect multiple decisions at once. The agent should update the spec and decisions log accordingly, then keep working.

No deploy or launch instruction is included in this package.