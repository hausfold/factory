---
name: nightshift
description: >-
  Take the factory's shift: grant the merge lease, loop `factory shift` on a
  cadence until it expires, spawn capped fixer lanes on red CI, and write the
  handover. Use when the user says /nightshift, "run the night shift", "take
  the shift", "keep shipping while I'm away/asleep", usually with a duration
  ("/nightshift 12h"). This skill is the foreman — the judgement half the
  deterministic scripts refuse to carry. For one-off verbs, load `factory`.
---

# nightshift — the foreman loop

You are taking the shift. The user is away; everything below runs without them,
and the shift log is your handover. Read `factory skill` once first.

## Start

1. `factory lease grant <duration>` — the duration from the invocation; no
   duration given means **1h**. Tell the user in one line what authority you now
   hold and until when.
2. `factory watchdog once` — confirm the poller `grant` just started is watching
   you. It is what turns your own death into something the user finds in the
   morning instead of a lease that stood all night with nobody exercising it.
   Exit **0** is what you want. **4** is `NO POLLER` — a live lease nothing is
   watching; say so in your start line. **1** means the grant did not take and
   there is no shift to run.
3. `factory shift --dry-run` — one sensing pass so your first real pass holds no
   surprises. If it shows `would-merge` rows the user can still see, name them.

## The loop

Cadence **~20 min**, using whatever timer your client has. Each wakeup:

1. `factory watchdog ensure` — the lease check and the liveness check in one,
   and it restarts a poller lost to a reboot or an OOM kill. Exit **1 → jump to
   Shift end** (the lease is gone). **3** means the watchdog thinks *you* have
   been quiet too long, which on a wakeup you are running means the last pass
   failed to log — read the shift log before doing anything else.
2. `factory shift`. The script merges, runs the after-merge hook and logs on its
   own; your job is only what it printed:
   - **`CI-RED <repo> <url>`** → maybe spawn a fixer (rules below).
   - **`merge-failed` / `after-merge-failed`** → **the line carries the reason;
     read it before doing anything.** A merge refused on `--match-head-commit`
     is the pin working — the branch moved after the verdict — and needs nothing
     at all. **A `merge-failed` is never re-driven by hand, whatever the reason
     says**: that is merging outside `factory shift`, against a head no verdict
     covers. An `after-merge-failed` you may retry once yourself; the line names
     which command stopped, and re-running the others is not the fix.
   - **`queued` rows need nothing** — they are the morning's, by design. Never
     merge one yourself, whatever the reason column says: the lease covers tier
     1 as the policy decides it, not as you would.
   - **`prs-unknown` / `tier-unknown` / `ci-unknown`** → the pass could not SEE
     that thing; it is not a verdict and not a quiet result. Run the pass again
     once. If the same line comes back, say so in your next message and, for a
     `ci-unknown`, check that repo yourself (`gh run list -R <repo> -b main
     -L1`) rather than carrying an unknown through the night. Never spawn a
     fixer off an unknown: you have not seen a failure, only a gap.
   - **`pass ABORTED`** (non-zero exit) → nothing sensed, nothing merged. Retry
     once; if it aborts again, stop retrying, keep the loop alive at the normal
     cadence, and report it.
   - **`foreman-stalled` / `foreman-resumed`** in the log → the watchdog saw you
     go quiet and you are back. Say so with the gap it names.
     **`machine-slept`** is the same line for a gap that was the machine's, not
     yours. **`foreman-gone`** you will never read — it is written as your lease
     is revoked.
3. Mark the wakeup quiet only when the pass merely sensed. **An `unknown` line
   or an abort is not a quiet night** — collapsing it into a run of quiet ticks
   is exactly the mistake those lines exist to prevent.

## Fixer lanes

On `CI-RED <repo> <url>`, all four must hold:

- **budget**: the pass's `budget:` line ends **`fixer: yes`** — else append
  `fixer-skipped: budget — <why>` to today's shift log and move on, where
  `<why>` is the text after `fixer: no`. Do **not** redo the arithmetic or
  reason around it: a threshold re-derived in prose is one nothing can test and
  nobody can see is stuck. `fixer: no (budget unknown)` is a refusal like any
  other — an unreadable quota is not permission;
- **cap**: fewer than **2** fixers for this repo tonight (count your own
  `fixer-spawned: <repo>` lines in today's log);
- **novelty**: no earlier fixer tonight was spawned for this same head SHA — a
  fix that broke CI again does not get a third machine;
- the failure is on the **default branch**, not a PR branch.

Spawn it as a real background agent session — never a headless one-shot that
stalls on its first permission prompt with nobody watching. Give it: the run
URL, then "diagnose from the run log, fix it, verify, commit, push, open a PR
titled `fix(ci): …`. Stop at PR open."

Then append `fixer-spawned: <repo> <head sha>` to today's shift log
(`~/.cache/factory/shift-*.log`). Both lines are yours to write: nothing in
`factory shift` knows a lane was considered, so a decision you only put in a
message is one the morning cannot read and the cap cannot count.

A fixer's PR is not special: if it is docs-only the next pass merges it; a code
fix waits for the morning like every other PR.

## Shift end

Lease expired, or the user says "end the shift":

1. Final `factory shift --dry-run`, so the log's last lines are the open state
   of the world.
2. Write the handover from today's log: merged (count + list), queued (with
   reasons), CI reds and what each fixer did, budget at close. Post it as your
   final message.
3. Stop the loop. Do not renew your own lease — only the user grants one.
   `factory lease revoke` stops the watchdog with it; a lease left to expire
   takes the watchdog down at its next poll, so neither needs stopping by hand.

## What this skill never does

Merge outside `factory shift`, widen the policy, activate or deploy anything,
touch releases, or spawn anything the budget line has not said `fixer: yes` to.
Quiet nights are good nights.

It also never stops the watchdog to quiet a `foreman-stalled` line, and never
re-grants a lease the watchdog revoked. Both are the shift reporting that it
stopped being able to do its job, and a foreman that silences either is the
exact failure those lines were added to make visible.
