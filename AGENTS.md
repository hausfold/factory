# AGENTS.md

**factory** — merge the pull requests code alone can vouch for, while nobody is
watching. Four bash scripts, one machine-local JSON policy, one log. This file
is for an agent working **on** factory, from a checkout; `ai/SKILL.md` is for an
agent **using** it on a machine that has no checkout. They are different
documents and neither substitutes for the other.

Standalone and repo-agnostic on purpose. The hausfold layer ships it on `PATH`,
but nothing here may assume hausfold: no `bench`, no `haus`, no org name, no
workshop layout. The org this repo lives in is not the org the tool watches —
that comes from the user's config, always.

## The shape

| | |
|---|---|
| `bin/factory` | the dispatcher, plus `config`, `doctor` and `skill`. Execs the libexec scripts; holds no policy of its own |
| `lib/common.sh` | config load + validation, the deny **floor**, the BSD/GNU `stat`/`date` shims, `notify`. Sourced, never executed |
| `lib/ui.sh` | how a line reaches the screen: `out_ok`/`out_warn`/`out_bad`/`out_info` on fd 1, `fail`/`hint`/`die` on fd 2, and snug's painter behind them. Separate from `common.sh` because `factory --help` must draw without `jq` |
| `libexec/factory-lease` | the standing merge grant |
| `libexec/factory-tier` | one PR's verdict. **The filter is the definition of tier 1** |
| `libexec/factory-shift` | one pass. Deterministic: no judgement lives here |
| `libexec/factory-watchdog` | notices the foreman died |
| `ai/SKILL.md`, `ai/nightshift/SKILL.md` | the agent surface — verbs, and the loop that drives them |

## Rules

- **Silence is a claim.** Every step that could fail to *see* degrades to a
  named line — `prs-unknown`, `tier-unknown`, `ci-unknown`, `pass ABORTED` —
  never to an answer that happens to parse, and never to nothing. A pass that
  looked at nothing must not print what a quiet night prints. This is the one
  invariant the whole design rests on; a change that adds a silent failure path
  is wrong however small.
- **The floor is not configurable, and the config is not in a repo.** Both are
  authority questions. `FACTORY_FLOOR_DENY` in `lib/common.sh` is what no
  policy may lower; the policy file is machine-local because a copy inside a
  watched repo would be a file a PR could edit to widen the filter judging it.
  Neither is a packaging detail to tidy away.
- **No environment variable may widen the merge filter, or lengthen the
  watchdog's patience.** `FACTORY_CONFIG` and `FACTORY_STATE_DIR` say *where*
  to read and `FACTORY_UI_SH` how to paint; nothing says *what may merge*. A
  variable that raised the line cap would be authority anything in the shift's
  environment could grant itself. The three the suites use to make a 45-minute
  threshold reachable in seconds — `FACTORY_STALE`, `FACTORY_DEAD`,
  `FACTORY_WATCHDOG_INTERVAL` — may only *shorten* the policy's number and are
  refused when they would not, because a poller inherits the environment of
  whoever ran `lease grant`, and on a night shift that is the foreman.
  `FACTORY_NO_WATCHDOG=1` stops `grant` spawning a poller, for a suite that
  must not leak one; it hides nothing, since `watchdog once` then reports NO
  POLLER at exit 4 and `doctor` carries that line.
- **Every deny clause needs a case that fails when it is deleted.** A clause
  that stops matching has no symptom until a PR someone meant to see merges at
  3 a.m. `test/factory-tier.bats` is the shape; the README's floor table and
  that suite are read against each other, so an exclusion added to one needs a
  row in the other in the same edit.
- **A number the README states is a number a test pins on both sides.** The
  budget dials live in `factory_defaults`; a pin that only greps the code is
  re-blessed by the same edit that breaks the doc.
- **`bash`, `jq`, `gh` and nothing else *required*.** No Go rewrite without a
  reason the bash cannot meet. It has to install with a `git clone` and a
  symlink on a machine with no Nix — which is why snug is an input and not a
  dependency: `lib/ui.sh` sources `$FACTORY_UI_SH` **if it is readable** and
  degrades to plain marked text if it is not. The Nix wrapper sets that
  variable at snug's store path; a cloned checkout has no wrapper, and prints
  the same report unpainted. A change that makes any verb *need* snug has
  broken the clone-and-symlink install.
- **A report draws on fd 1; only an error draws on fd 2.** `doctor`'s checklist,
  `tier`'s verdict, `lease status` and every line of a `shift` are what the user
  ran the command for, so `factory shift >> nightly.log` has to come out whole —
  and escape-free, which it does because snug gates and measures each stream
  about its own far end. `fail`, `hint` and `die` are the fd-2 half. The
  standard is `hausfold/snug`'s README and AGENTS.md; `test/presentation.bats`
  is what holds factory to it, including a blanket ban on a literal escape
  anywhere in `bin/`, `libexec/` or `lib/`.
- **A flag a verb does not implement is refused, never ignored.** `doctor
  --json` printed the human checklist and exited 0 for as long as `cmd_doctor`
  never looked at `$@`, and an agent handed prose back cannot tell "this verb
  has no JSON" from "the JSON is malformed". Every verb parses its own flags and
  dies on one it does not know — on fd 2, with nothing on fd 1. A flag it DOES
  know, handed no value or an empty one, is the same refusal: `shift 2` past the
  end of `$@` returns 1 and `set -e` turns that into an exit with nothing on
  either stream, and an empty value is an unset shell variable rather than a
  request — falling through to a default there acts on a request nobody made.
  `test/agent-surface.bats` is what holds the dispatcher to that, and a new flag
  belongs in the same edit as the case that proves the old ones still refuse.
- **One verb never parses another's human line.** `shift` asks `tier` and
  `lease` for `--json` and reads fields out of it. The human line carries a mark
  in its gutter and is folded to the window; both are presentation, and both
  have already broken a caller that treated the line as a contract.
- **Portable between BSD and GNU.** The Mac holds the lease and the CI runner is
  Ubuntu. `stat` and `date` are probed once in `lib/common.sh` — never
  `bsd_form || gnu_form`, which appends the right answer to the wrong one.
- Verify with `bats test/` and `shellcheck -x bin/factory libexec/* lib/*.sh
  script/*.sh`. Both are what CI runs.

## Releasing

CalVer, cut from `main`. `VERSION` is read by `flake.nix` to name the
derivation; a tag is what publishes.
