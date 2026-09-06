# AGENTS.md

**factory** merges the pull requests code alone can vouch for: four bash
scripts, a machine-local JSON policy, a log. **`README.md` is the manual.**

Standalone: never assume hausfold (`bench`, `haus`, an org name); the org it
watches comes from config.

## The shape

| | |
|---|---|
| `bin/factory` | dispatcher, plus `config`, `doctor`, `skill`. Holds no policy |
| `lib/common.sh` | config + validation, the deny floor, `stat`/`date` shims, `notify`. Sourced, never executed |
| `lib/ui.sh` | `out_ok`/`out_warn`/`out_bad`/`out_info` on fd 1, `fail`/`hint`/`die` on fd 2. Separate so `factory --help` draws without `jq` |
| `libexec/factory-lease` | the merge grant. Live (`lease status`), tier 1 merges; nothing else does |
| `libexec/factory-tier` | one PR's verdict. **The filter is the definition of tier 1** |
| `libexec/factory-shift` | one pass, deterministic |
| `libexec/factory-watchdog` | the runner: `factory shift` every `runner.interval` under a live lease, each `ci-red` through the four fixer gates, revokes when passes stop landing |
| `ai/SKILL.md` | the agent surface: the verbs. The loop is the runner |

## Rules

- **Silence is a claim.** A step that could fail to see prints a named line,
  `prs-unknown`, `tier-unknown`, `ci-unknown`, `pass ABORTED`, never nothing.
- **`FACTORY_FLOOR_DENY` (`lib/common.sh`) is not configurable, and the policy
  is machine-local**: `factory config print` is its only statement.
- **No environment variable may widen the filter or lengthen the watchdog's
  patience.** `FACTORY_CONFIG`, `FACTORY_STATE_DIR` say where; `FACTORY_UI_SH`
  how to paint; `FACTORY_STALE`, `FACTORY_DEAD`, `FACTORY_WATCHDOG_INTERVAL`,
  `FACTORY_RUNNER_INTERVAL` only shorten, refused otherwise.
  `FACTORY_NO_WATCHDOG=1` stops `lease grant` spawning a runner; `watchdog once`
  then reports NO RUNNER, exit 4.
- **Four fixer gates, in code, each refusal a line.** A `ci-red` gets a
  lane only if `fixer.command` is set, no shift log holds `fixer-spawned` for
  its head SHA, today's holds fewer than `fixer.cap` for the repo, and the
  pass's `budget` event said `fixer: true`; else `fixer-skipped` naming the
  gate, or `fixer-failed` with stderr. `test/factory-watchdog.bats`: a case
  per gate.
- **Every deny clause needs a case that fails when it is deleted**:
  `test/factory-tier.bats`, edited with the README's floor table.
- **A number the README states, a test pins on both sides.** Dials:
  `factory_defaults`.
- **`bash`, `jq`, `gh`, nothing else**: it installs by `git clone` and a
  symlink. `lib/ui.sh` sources `$FACTORY_UI_SH` (snug's `share/ui.sh`, from
  the Nix wrapper) only if readable, else prints plain marks; no verb may need
  snug.
- **A report draws on fd 1, an error on fd 2**, so
  `factory shift >> nightly.log` is whole and escape-free. `hausfold/snug`'s
  README and AGENTS.md are the standard; `test/presentation.bats` holds it and
  bans literal escapes in `bin/`, `libexec/`, `lib/`.
- **An unknown flag, or a known one with no or an empty value, is refused,
  never ignored**: fd 2, nothing on fd 1. `test/agent-surface.bats`; a new flag
  lands with its case.
- **One verb never parses another's human line.** `shift` reads `tier` and
  `lease` through `--json`.
- **BSD and GNU.** `stat` and `date` are probed once in `lib/common.sh`, never
  `bsd_form || gnu_form`.
- Verify: `bats test/` and `shellcheck -x bin/factory libexec/* lib/*.sh
  script/*.sh`, what CI runs.

## Releasing

CalVer from `main`. `flake.nix` reads `VERSION`; a tag publishes.
