---
name: factory
description: >-
  Merge the pull requests that a reviewed filter can vouch for, without waking
  the user — and check what a night of that did. Use when the user says "merge
  the safe PRs", "what did the factory do last night", "grant/revoke the merge
  lease", "keep shipping while I'm asleep", "is anything red on main", "why
  didn't PR N merge", "can we afford a fixer lane", or asks to run one pass of
  the shift. A live lease runs the shift on its own; this skill is the verbs
  around it and how to read what it wrote.
---

# factory — merge what code alone can vouch for

`factory` merges the fraction of open PRs a **policy the user typed** can vouch
for (by default: docs-only, from their own branch, green, no renames), watches
the default branch's CI, and queues everything else for the morning. It never
decides with a model, never writes PRs, and never merges without a live lease.

**Its failure mode is the status quo**: no lease, an expired one, or a pass that
could not see leaves every PR open, exactly where it is today.

**The lease is the on/off switch.** `factory lease grant 12h` starts a runner
(`factory watchdog run`) that passes `factory shift` every 20 minutes until the
lease ends, spawns a fixer lane on a red default branch when four gates in
code allow it, and revokes the lease if its passes stop landing. No agent
session drives it. The shift log is the handover.

## Verbs

| do this | run this |
|---|---|
| take merge authority for a while | `factory lease grant 12h` |
| take it until told otherwise | `factory lease grant indefinitely` |
| check / drop that authority | `factory lease status` · `factory lease revoke` |
| sense everything, merge nothing | `factory shift --dry-run` |
| one real pass, by hand | `factory shift` |
| ask why one PR is not mergeable | `factory tier <owner/repo> <number>` |
| read the effective policy | `factory config print` |
| is this machine able to run a shift | `factory doctor` |
| are passes landing under the lease | `factory watchdog once` |
| last night's report | `cat ~/.cache/factory/shift-$(date +%Y%m%d).log` |

Every read verb takes `--json` — `doctor` included, where it returns one
document with a `checks[]` array, a `ready` boolean and the `lease`/`watchdog`
objects nested whole. `factory shift --json` emits one JSON object per event. A
flag a verb does not know is refused on stderr, so prose back from a `--json`
run always means the run failed, never that the verb had no JSON to give.

## When to reach for this

- "merge the docs PRs" / "clear the safe ones" → `factory shift --dry-run`
  first, then `factory shift` under a lease
- "keep shipping while I'm away" → `factory doctor`, then
  `factory lease grant <duration>`. That is the whole start: the runner does
  the rest. Confirm with `factory watchdog once` (exit 0), and tell the user
  in one line what authority stands and until when
- "why is #212 still open?" → `factory tier <repo> 212` — the refusal names its
  own reason
- "what happened last night?" → read today's (or yesterday's) shift log
- "stop it merging things" → `factory lease revoke`
- "can it merge X too?" → that is a policy edit at `factory config path`, and it
  is the user's call, never yours

## Reading the log

- `merged` / `queued` / `would-merge` — verdicts. `queued` waits for a person by
  design.
- `CI-RED <repo> <url>` — the default branch is red. The lines right after it
  say what the runner did about it: `fixer-spawned: <repo> <sha>`, or
  `fixer-skipped: <repo> — <gate>` naming which of the four gates refused
  (no `fixer.command`, same head SHA already had a lane, `fixer.cap` reached
  today, or budget), or `fixer-failed` with the command's stderr.
- `pass-retry: <event> — one more pass at the next tick` — the runner saw an
  unknown or an abort and is running once more. Two of the same unknown in a
  row is a story for the user, not something to fix.
- `shift-stalled` / `shift-resumed` / `shift-dead` — passes stopped landing
  under a live lease, resumed, or stopped long enough that the runner revoked
  the lease. `machine-slept` is a gap that was the machine's. `shift-over` is
  the lease ending the ordinary way.
- `pass-failed` — `factory shift` exited before it could write anything. The
  line quotes why; it is usually the config.

## When NOT to

- **Never merge a PR the shift queued.** A `queued:` line is a verdict: the PR
  waits for a person by design. Merging it by hand is the one thing the lease
  does not cover.
- **Never re-drive a `merge-failed` by hand.** The line names why. A head that
  moved under `--match-head-commit` is the pin working; the next pass re-judges
  it against the new head.
- **Never widen `tier1` to get something through.** The filter is the whole
  definition of what may merge unattended.
- **Never loop `factory shift` yourself while a lease is live.** The runner is
  already doing it, on the cadence the policy names. A pass by hand is fine;
  a second loop is two things merging under one grant.
- **Never spawn a fixer lane yourself off a `CI-RED` line.** The four gates are
  in code and their verdict is the line after it. A lane the gates refused is
  a lane the budget or the cap said no to.
- Opening PRs, reviewing code, releasing — none of that is here.

## Traps

- **`fixer: no (budget unknown)` is a refusal, not a gap to reason around.** An
  unreadable quota is not permission. Do not re-derive the arithmetic in prose.
- **`queued` and `tier-unknown` look alike and are opposites.** `queued` was
  judged and refused; `tier-unknown` means nothing judged it. The second one is
  a PR nobody has looked at.
- **`ci-unknown` is not a green branch**, and `prs-unknown` is not a repo with
  no PRs. Both mean the pass was blind there. The runner retries once on its
  own; if the line repeats, say so.
- **A `pass ABORTED` exits non-zero and merged nothing.** Nothing was sensed —
  do not report it as a quiet night.
- **The policy file is machine-local** (`factory config path`), deliberately: a
  copy inside a repo would be a file a PR could edit to widen the filter judging
  it. Do not add one to a repo.
- **The lease is the user's grant.** Never grant one to get past a refusal, and
  never re-grant one the runner revoked — `shift-dead` is the runner reporting
  its passes stopped landing, and the reason is in the lines above it.
- Exit codes: `0` ok/tier 1 · `1` no lease, or an aborted pass · `2` usage or
  bad config · `3` refused / shift stalled · `4` live lease, no runner.
  **`doctor` is the exception**: `0` ready with nothing to note, `1` ready
  **with notes**, `2` blocking. A ready machine usually exits 1, so read
  `.ready` rather than the code.

Then `factory --help` for the exhaustive flag list.
