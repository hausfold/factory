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
- **No environment variable may widen the merge filter.** `FACTORY_CONFIG` and
  `FACTORY_STATE_DIR` say *where* to read; nothing says *what may merge*. A
  variable that raised the line cap would be authority anything in the shift's
  environment could grant itself.
- **Every deny clause needs a case that fails when it is deleted.** A clause
  that stops matching has no symptom until a PR someone meant to see merges at
  3 a.m. `test/factory-tier.bats` is the shape; the README's floor table and
  that suite are read against each other, so an exclusion added to one needs a
  row in the other in the same edit.
- **A number the README states is a number a test pins on both sides.** The
  budget dials live in `factory_defaults`; a pin that only greps the code is
  re-blessed by the same edit that breaks the doc.
- **`bash`, `jq`, `gh` and nothing else.** No Go rewrite without a reason the
  bash cannot meet; no other runtime dependency at all. It has to install with
  a `git clone` and a symlink on a machine with no Nix.
- **Portable between BSD and GNU.** The Mac holds the lease and the CI runner is
  Ubuntu. `stat` and `date` are probed once in `lib/common.sh` — never
  `bsd_form || gnu_form`, which appends the right answer to the wrong one.
- Verify with `bats test/` and `shellcheck -x bin/factory libexec/* lib/*.sh
  script/*.sh`. Both are what CI runs.

## Releasing

CalVer, cut from `main`. `VERSION` is read by `flake.nix` to name the
derivation; a tag is what publishes.
