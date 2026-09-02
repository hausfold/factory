---
name: factory
description: >-
  Merge the pull requests that a reviewed filter can vouch for, without waking
  the user — and check what a night of that did. Use when the user says "merge
  the safe PRs", "what did the factory do last night", "grant/revoke the merge
  lease", "is anything red on main", "why didn't PR N merge", "can we afford a
  fixer lane", or asks to run one pass of the shift. For running the shift on a
  cadence overnight, load the `nightshift` skill instead — that one is the loop,
  this one is the verbs.
---

# factory — merge what code alone can vouch for

`factory` merges the fraction of open PRs a **policy the user typed** can vouch
for (by default: docs-only, from their own branch, green, no renames), watches
the default branch's CI, and queues everything else for the morning. It never
decides with a model, never writes PRs, and never merges without a live lease.

**Its failure mode is the status quo**: no lease, an expired one, or a pass that
could not see leaves every PR open, exactly where it is today.

Nothing runs on a schedule. One `factory shift` is one pass; something has to
call it — usually a person, or an agent driving the `nightshift` loop.

## Verbs

| do this | run this |
|---|---|
| take merge authority for a while | `factory lease grant 12h` |
| check / drop that authority | `factory lease status` · `factory lease revoke` |
| sense everything, merge nothing | `factory shift --dry-run` |
| one real pass | `factory shift` |
| ask why one PR is not mergeable | `factory tier <owner/repo> <number>` |
| read the effective policy | `factory config print` |
| is this machine able to run a shift | `factory doctor` |
| is the foreman alive | `factory watchdog once` |
| last night's report | `cat ~/.cache/factory/shift-$(date +%Y%m%d).log` |

Every read verb takes `--json` — `doctor` included, where it returns one
document with a `checks[]` array, a `ready` boolean and the `lease`/`watchdog`
objects nested whole. `factory shift --json` emits one JSON object per event. A
flag a verb does not know is refused on stderr, so prose back from a `--json`
run always means the run failed, never that the verb had no JSON to give.

## When to reach for this

- "merge the docs PRs" / "clear the safe ones" → `factory shift --dry-run`
  first, then `factory shift` under a lease
- "why is #212 still open?" → `factory tier <repo> 212` — the refusal names its
  own reason
- "what happened last night?" → read today's (or yesterday's) shift log
- "stop it merging things" → `factory lease revoke`
- "can it merge X too?" → that is a policy edit at `factory config path`, and it
  is the user's call, never yours

## When NOT to

- **Never merge a PR the shift queued.** A `queued:` line is a verdict: the PR
  waits for a person by design. Merging it by hand is the one thing the lease
  does not cover.
- **Never re-drive a `merge-failed` by hand.** The line names why. A head that
  moved under `--match-head-commit` is the pin working; the next pass re-judges
  it against the new head.
- **Never widen `tier1` to get something through.** The filter is the whole
  definition of what may merge unattended.
- Opening PRs, reviewing code, releasing — none of that is here.

## Traps

- **`fixer: no (budget unknown)` is a refusal, not a gap to reason around.** An
  unreadable quota is not permission. Do not re-derive the arithmetic in prose.
- **`queued` and `tier-unknown` look alike and are opposites.** `queued` was
  judged and refused; `tier-unknown` means nothing judged it. The second one is
  a PR nobody has looked at.
- **`ci-unknown` is not a green branch**, and `prs-unknown` is not a repo with
  no PRs. Both mean the pass was blind there. Run it again once; if it repeats,
  say so.
- **A `pass ABORTED` exits non-zero and merged nothing.** Nothing was sensed —
  do not report it as a quiet night.
- **The policy file is machine-local** (`factory config path`), deliberately: a
  copy inside a repo would be a file a PR could edit to widen the filter judging
  it. Do not add one to a repo.
- **The lease is the user's grant.** Never grant one to get past a refusal, and
  never re-grant one the watchdog revoked — that revocation is the watchdog
  reporting the shift stopped being run.
- Exit codes: `0` ok/tier 1 · `1` no lease, or an aborted pass · `2` usage or
  bad config · `3` refused / foreman stalled · `4` live lease, no poller.

Then `factory --help` for the exhaustive flag list.
