# Claude Code Notes

This file is kept because Claude Code reads `CLAUDE.md` by convention.

The shared, vendor-neutral agent instructions live in:

- [`AGENTS.md`](AGENTS.md) — the lab-router-specific agent brief
- [`../dev-commons/AGENTS.md`](../dev-commons/AGENTS.md) — the
  sibling-family agent brief
- [`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) — read first
  if you are new to the project
- [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) — coding /
  scripting / docs conventions

Claude-specific interpretation:

- Treat `AGENTS.md` as the authoritative project brief.
- Keep `.claude/` local and private (already gitignored).
- Do not put general project knowledge only in `.claude/`; promote
  useful knowledge into tracked docs (in this repo) or into
  `../dev-commons/` (cross-cutting).
