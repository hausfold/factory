# factory

**Merge the pull requests code alone can vouch for, while nobody is watching.**

On an ordinary week a small org lands ~100 PRs, and every one of them waits for
a person to press merge. Most of that waiting is not review — it is a docs typo
sitting overnight because the human who would have merged it was asleep.

`factory` merges the fraction a filter can vouch for, watches the default
branch's CI, and leaves everything with taste in it for the morning. It is four
bash scripts, a JSON policy file and a log. There is no daemon, no webhook, no
service to sign up for, and nothing that phones anywhere.

**Its failure mode is the status quo.** No lease, an expired lease, a pass that
could not see, a foreman that died — every one of them leaves your PRs exactly
where they are today: open, waiting for you.

```sh
brew install jq gh          # the only two dependencies
git clone https://github.com/hausfold/factory ~/.local/share/factory
ln -s ~/.local/share/factory/bin/factory /usr/local/bin/factory

factory config init         # writes ~/.config/factory/config.json
$EDITOR "$(factory config path)"
factory doctor              # is this machine able to run a shift?
factory shift --dry-run     # sense everything, merge nothing
```

Then, when you trust what the dry run said:

```sh
factory lease grant 12h     # authority to merge tier 1, until then
factory shift               # one pass — loop it, or drive it from an agent
```

---

## The four verbs

| | |
|---|---|
| `factory lease` | the standing merge grant. `grant 12h` / `status` / `revoke`. One line in a machine-local state file — so no pull request can ever grant itself authority |
| `factory tier` | is one PR **tier 1**, i.e. mergeable by code alone? Decided by the policy you typed, never by a model's read of the diff |
| `factory shift` | one pass: read the budget, judge every open PR, merge tier 1 under a live lease, run your after-merge hook, report a red default branch. `--dry-run` senses and merges nothing |
| `factory watchdog` | notice that the *foreman* died, which no pass can report. Started automatically by `lease grant` |

Plus the surface around them: `factory config print`, `factory doctor`,
`factory skill`, `factory --help`.

## Exit codes

| | |
|---|---|
| **0** | ok · tier 1 · foreman healthy |
| **1** | nothing (no live lease) · a pass that aborted having sensed nothing |
| **2** | usage, or a config that cannot be used |
| **3** | refused (not tier 1) · foreman stalled |
| **4** | a live lease with no poller watching it |

Every read verb takes `--json`. `factory shift --json` emits one JSON object
per event on stdout while the human log stays human.

---

## The policy file

One file, machine-local, at `factory config path`
(`~/.config/factory/config.json`, or `$FACTORY_CONFIG`). `factory config print`
shows the **effective** policy — your file merged over the defaults — so you can
always tell *unset* from *set to the default*.

```json
{
  "scope": {
    "orgs": ["your-org"],
    "repos": ["someone/one-more-repo"],
    "exclude": ["a-repo-with-actions-disabled"]
  },
  "tier1": {
    "allow": ["^docs/", "\\.md$"],
    "deny": [],
    "base": "main",
    "head": "^worktree-",
    "authors": ["@me"],
    "maxLines": 2000,
    "requireGreen": "if-present",
    "mergeMethod": "squash"
  },
  "afterMerge": {
    "workdir": "~/code/my-project",
    "commands": ["make lockfiles", "git push"]
  },
  "budget": { "mode": "metered", "feed": "~/.cache/usage.tsv" },
  "notify": { "mode": "auto", "source": "factory" }
}
```

**It is machine-local because it is authority.** A copy inside a watched repo
would be a file a pull request could edit to widen the filter that judges it —
the same reason the lease is not a checked-in file. It also describes a *fleet*
rather than a repo, so a per-repo file would be the wrong shape even if it were
safe. What you give up is in-repo review of a policy change; what you get back
is the `policy:` line at the top of every pass, naming the digest of the policy
that merged tonight.

## Tier 1, and why it is code rather than judgement

The merge decision is the one act with no undo-by-default, so it is made by a
filter you reviewed, not by a model's read of the diff. The default is
deliberately narrow: **a docs-only PR — every changed file matching
`tier1.allow`, none of it renamed — opened by you from a `worktree-*` branch
onto `main`, green, conflict-free, and under 2000 changed lines.**

An agent's judgement enters exactly twice, both bounded: writing the PRs in the
first place, and deciding whether a red CI run is worth a fixer lane. Everything
`factory shift` refuses is **queued**, never closed — the verdict and its reason
land in the log, and the PR waits where it always has.

### The floor `tier1.deny` sits on top of

Some paths are never tier 1 however you write your policy, because they are not
prose even when they are markdown:

| never tier 1 | why |
|---|---|
| `AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, any `SKILL.md` | a merged steering file changes how every agent on the machine behaves. That is policy, and a policy change meets a person |
| `.github/` | a workflow merged unattended is arbitrary code running with the repo's own token |
| `.claude/`, `.agents/`, `.codex/`, `.cursor/`, `.gemini/`, `.opencode/` | the same argument, one directory per client |
| `content/` | a repo whose default branch deploys a site turns a docs merge into a *publish*, and a user-facing publish is always gated |
| anything **renamed** | a rename is a delete wearing a docs name |

The deny tests are case-insensitive because APFS is: a merged `docs/claude.md`
is what a tool opening `docs/CLAUDE.md` actually reads.

`test/factory-tier.bats` has a case per clause, each written so that deleting
the clause fails it — because a deny clause that stops matching has no symptom
until a PR someone meant to see merges at 3 a.m.

### `requireGreen`

`if-present` (the default) forgives a PR that reported no checks, because plenty
of docs repos run no CI on pull requests at all. Set it to `always` where CI is
the whole verification story: there, a workflow that failed to *trigger* is
indistinguishable from one that passed, and `always` refuses to guess.

---

## A pass that cannot see

The shift's product is a log somebody reads instead of having watched, so
**silence in it is a claim** — the claim that something was looked at and was
fine. Four lines exist so that claim is never made on the shift's behalf by a
step that failed:

| line | what could not be seen | exit |
|---|---|---|
| `prs-unknown: <repo>` | that repo's open PRs would not list, so none was judged this pass | 0 |
| `tier-unknown: <repo>#<n>` | no verdict for this PR. **Distinct from `queued`,** which *is* a verdict: a named refusal | 0 |
| `ci-unknown: <repo>` | that repo's latest run would not read, so it is not known to be green | 0 |
| `pass ABORTED` | the repo listing failed or came back empty, so nothing was sensed at all | **non-zero** |

Each carries the failing command's first line of stderr, because the only
question a reader has is whether a repeat is a story — and a rate limit, an
expired token and a dropped connection are the same line without it.

The two lines that report a failed **write** carry the same evidence for the
same reason. `merge-failed` and `after-merge-failed` are verdicts rather than
unknowns — the pass saw everything and the action did not take — but "did not
take" spans a head that moved under `--match-head-commit`, which is the pin
working exactly as designed and needs nothing, and a token that expired three
hours ago, which means the shift has been over since then.

## The budget governor

Merging and sensing are `gh` calls and cost no tokens. Exactly one thing is
throttled: **can the account afford an agent lane right now.**

Point `budget.feed` at a TSV whose first four columns are `5-hour %`,
`weekly %`, `5-hour reset epoch`, `weekly reset epoch`, and every pass ends its
budget line in a verdict:

```
budget: 5h 13% · week 16% · reserve 58 pts · headroom 21 pts · fixer: yes
```

Two conditions, both protecting the human's hours. First, the **5-hour window
under 80%** — a factory that saturates the rolling window at 4 a.m. is
rate-limiting the person who sits down at 9, and that outranks the weekly half.
Second, **enough weekly headroom left for one lane**: `reserve` (70) points of
the weekly window are the human's, draining evenly as the week runs off, so the
reserve right now is `70 × (fraction of the week remaining)`. What sits between
that and the `ceiling` (95; the top five points are nobody's) is the factory's
to spend, and a lane needs `fixer` (5) points of it.

The question is **forward-looking**, and that is the load-bearing part. "Is the
week spent no faster than the clock so far" is a question nobody has, and it
cannot be answered yes by anything but an idle week: spend only rises and the
clock does not rewind, so one honest burst on Monday reads over-budget until the
reset however much is left. Asking instead whether a lane *still leaves enough
to finish the week* forgives the burst and keeps the bound.

**Every arm that could not do the arithmetic ends `fixer: no (budget unknown)`.**
A missing feed, a column reorder upstream, a value that is not digits, a reset
stamp absent or further out than the week it names. An unknown budget is not
permission, for the same reason `ci-unknown` is not a green branch.

No quota to count? `"budget": {"mode": "unmetered"}` says so out loud, and the
log says it too — so a feed that merely went missing can never be mistaken for a
decision you made.

## When the foreman dies

The unknown lines above keep a pass that could not *see* from reading as a quiet
night. The watchdog is the layer under them, and it exists because every one of
those lines has to be written by a pass that RAN.

A foreman is usually an agent session driving a loop, and that loop continues
only if a turn completes and schedules the next wakeup. A turn that ends in an
error schedules nothing. Nothing is then left running, so nothing is left to
report it: the log's last line is an ordinary `pass done: 0 merged`, and the
lease goes on standing for hours with nobody exercising it.

The heartbeat is the shift log's mtime, read as the **later** of that and the
lease's own grant stamp. Two thresholds, because a blip and a death want
different answers: at **45 minutes** quiet the watchdog writes `foreman-stalled`
and cards it once, and the lease stands; at **90** it writes `foreman-gone` and
**revokes the lease**, so the morning finds the ordinary human-in-the-loop
workflow rather than a standing grant nobody is exercising.

Both thresholds count time the poller was **awake** for. A machine that
suspended has a stale log through nobody's fault — the watchdog was not running
either — so the loop measures how long its own `sleep` actually took and
subtracts the excess, writing `machine-slept` for the record. Subtracted rather
than forgiven with a grace window: a laptop that suspends and wakes all night
renews a grace window faster than it expires, and a genuinely dead foreman would
keep its lease until morning.

The watchdog deliberately **does not run `factory shift` itself.** It could; the
script is deterministic and the lease is the authority it would run under. But
merging with no foreman means a red CI nobody reads and a `merge-failed` nobody
retries — a factory that keeps its hands moving after its eyes have closed.

## Driving it from an agent

`factory shift` is one pass. Something has to call it on a cadence, decide
whether a red branch is worth a fixer, and write the handover — that is the
**foreman**, and it is the only part with judgement in it.

```sh
factory skill            # the routing document for a coding agent
factory skill install    # into every agent client on this machine
```

An agent that has the skill knows the verbs, the log vocabulary, the four
unknown lines, and the two rules that matter: never merge outside
`factory shift`, and never spawn a lane the budget line has not said
`fixer: yes` to.

## Overnight on a closed lid

macOS sleeps on lid-close regardless of `caffeinate`. The lever that actually
crosses a lid close is `sudo pmset -a disablesleep 1` (and the Mac has to be on
power). Asleep, the loop pauses rather than stops — but "pauses" is a claim
about the scheduler, not about the network: a wakeup that fires into an
interface that has not reassociated is a turn that errors, and that turn is the
end of the shift unless the watchdog is running. Both halves are needed.

## What it deliberately does not do

- **It does not decide what to merge with a model.** The filter is the whole
  definition of tier 1.
- **It does not write PRs.** Something else opens them; this closes the ones
  nobody needed to read.
- **It does not phone anywhere.** No telemetry, no service, no account.
- **It does not run headless.** A merge nobody is awake to notice is the thing
  the watchdog exists to prevent, not a feature.

## Development

```sh
bats test/                                    # 87 cases
shellcheck bin/factory libexec/* lib/*.sh
```

MIT. Part of the [hausfold](https://github.com/hausfold) family — the layer
ships it on `PATH`, but nothing here needs it.
