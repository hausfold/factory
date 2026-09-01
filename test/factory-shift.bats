#!/usr/bin/env bats
# Unit tests for `libexec/factory-shift` — and specifically for the passes that
# CANNOT see, which are the ones a night shift has to get right.
#
# The shift's product is a log somebody reads in the morning instead of having
# watched. So the failure that matters is not a crash: it is a pass that sensed
# nothing, said nothing about that, and ended on output identical to a quiet
# night. There are four ways to be blind — the repo list, one repo's PR list,
# one PR's tier verdict, one repo's default-branch CI — and each has a case below.
#
# `gh`, `trill` and `factory-tier` are all stubbed. Stubbing `trill` is not
# tidiness: `setup()` PREPENDS to PATH, so a real `trill` on a developer's
# machine is still found by `notify`'s `command -v`, and several cases here
# reach a `notify fault`. The screen belongs to whoever is sitting at it, and
# running a test suite is never a reason to take it. The stub also records its
# calls, which makes the notify POLICY testable — see the pair of cases on it.

setup() {
  TMP="$BATS_TEST_TMPDIR"
  # A throwaway tree. `factory-shift` resolves its siblings by path
  # (`$(dirname $0)/factory-tier`) and its library one level up, not through
  # PATH, so a stub for one of those has to sit where the script looks rather
  # than in front of it.
  mkdir -p "$TMP/root/libexec" "$TMP/root/lib" "$TMP/bin"
  cp "$BATS_TEST_DIRNAME/../libexec/factory-shift" "$TMP/root/libexec/"
  cp "$BATS_TEST_DIRNAME/../libexec/factory-lease" "$TMP/root/libexec/"
  cp "$BATS_TEST_DIRNAME/../lib/common.sh" "$TMP/root/lib/"
  cp "$BATS_TEST_DIRNAME/../VERSION" "$TMP/root/"
  SHIFT="$TMP/root/libexec/factory-shift"

  export FACTORY_STATE_DIR="$TMP/state"
  # The policy this suite runs under. One org, so the repo list is the stub's;
  # a usage feed that does not exist yet, so the budget line degrades to a
  # stated unknown until a case writes one; and an after-merge hook of two
  # commands in the throwaway root, which is what `stub_bench` writes.
  #
  # Nothing here depends on the real machine's quota, lease or config.
  export FACTORY_CONFIG="$TMP/config.json"
  cat >"$TMP/config.json" <<EOF
{
  "scope": { "orgs": ["hausfold"] },
  "budget": { "feed": "$TMP/usage.tsv" },
  "afterMerge": { "workdir": "$TMP/root", "commands": ["./bench pull", "./bench ship"] }
}
EOF

  PATH="$TMP/bin:$PATH"
  export PATH
  export TRILL_CALLS="$TMP/trill-calls"
  # Stubbing `trill` is not tidiness: `setup` PREPENDS to PATH, so a real trill
  # on a developer's machine is still found by `notify`'s `command -v`, and
  # several cases here reach a `notify fault`. The screen belongs to whoever is
  # sitting at it, and running a test suite is never a reason to take it.
  cat >"$TMP/bin/trill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRILL_CALLS"
EOF
  chmod +x "$TMP/bin/trill"
  export GH_MERGE_CALLS="$TMP/gh-merge-calls"

  stub_gh ok green none
  stub_tier 3
  stub_bench ok ok
}

# The after-merge hook's two commands, stubbed separately because the pass
# reports WHICH of them stopped. They run in `afterMerge.workdir`, which the
# config above points at the throwaway root, so the stub goes there.
stub_bench() { # $1 bench pull: ok | fail · $2 bench ship: ok | fail
  cat >"$TMP/root/bench" <<EOF
#!/usr/bin/env bash
case "\$1" in
pull) case "$1" in fail) echo "bench: perch is dirty — commit or park first" >&2; exit 1 ;; esac ;;
ship) case "$2" in fail) echo "bench: edge haus → snug did not move" >&2; exit 1 ;; esac ;;
esac
EOF
  chmod +x "$TMP/root/bench"
}

# A live lease, written directly rather than through `factory-lease grant` —
# `grant` spawns a real watchdog poller, and a leaked one would outlive the
# test that spawned it. `factory-lease status` is the only reader here, and
# this is the file it reads.
grant_lease() {
  mkdir -p "$FACTORY_STATE_DIR"
  printf '%s\t1\t%s\n' "$(($(date +%s) + 3600))" "$(date +%s)" \
    >"$FACTORY_STATE_DIR/lease"
}

# $1 gh repo list: ok | fail | empty
# $2 gh run list:  green | red | fail
# $3 gh pr list:   none | one | fail
# $4 gh pr merge:  ok | fail  (only reached with a lease granted; see below)
stub_gh() {
  cat >"$TMP/bin/gh" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
"pr merge")
  # Recorded rather than merely answered: --match-head-commit is the pin that
  # makes a push landing between the verdict and the merge fail closed, and a
  # pin nothing reads back is a pin that can quietly stop being passed.
  printf '%s\n' "\$*" >>"\$GH_MERGE_CALLS"
  case "${4:-ok}" in
  fail) echo "GraphQL: Head branch was modified. Review and try the merge again." >&2; exit 1 ;;
  esac
  ;;
"repo list")
  case "$1" in
  fail)  echo "connection reset by peer" >&2; exit 1 ;;
  empty) exit 0 ;;
  *)     echo "hausfold/perch" ;;
  esac
  ;;
"pr list")
  case "$3" in
  fail) echo "http2: client conn could not be established" >&2; exit 1 ;;
  one)  printf '7\tsomething\n' ;;
  esac
  ;;
"run list")
  case "$2" in
  fail) echo "http2: client conn could not be established" >&2; exit 1 ;;
  red)  printf 'failure\thttps://example.invalid/run/1\n' ;;
  *)    printf 'success\thttps://example.invalid/run/1\n' ;;
  esac
  ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
}

# $1 = the exit code factory-tier returns: 0 judged tier-1 · 3 judged refusal ·
# anything else is `set -e` aborting inside it, i.e. no verdict at all.
stub_tier() {
  case "$1" in
  0) body='echo "tier: 1 (hausfold/perch#7 · 1 files, 2 lines) head=deadbeef"; exit 0' ;;
  3) body='echo "tier: not-1 — touches AGENTS.md  (hausfold/perch#7)"; exit 3' ;;
  *) body='echo "gh: connection reset by peer" >&2; exit 1' ;;
  esac
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$TMP/root/libexec/factory-tier"
  chmod +x "$TMP/root/libexec/factory-tier"
}

# ── the two controls: what a seeing pass says must not move ───────────────────

@test "a readable, green main says nothing about CI and ends on a clean pass" {
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"pass done: 0 merged"* ]]
  [[ "$output" != *"CI-RED"* ]]
  # Named one by one rather than a bare *unknown*: the budget line legitimately
  # says "budget: unknown" here, having no usage feed, and a blanket match on
  # the word would pass for the wrong reason on a machine that has one.
  [[ "$output" != *"ci-unknown"* ]]
  [[ "$output" != *"prs-unknown"* ]]
  [[ "$output" != *"tier-unknown"* ]]
  [[ "$output" != *"ABORTED"* ]]
}

@test "a red main is still reported" {
  stub_gh ok red none
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"CI-RED: hausfold/perch"* ]]
}

@test "a PR that WAS judged and refused is still queued, with its reason" {
  stub_gh ok green one
  stub_tier 3
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"queued: hausfold/perch#7"* ]]
  [[ "$output" == *"touches AGENTS.md"* ]]
  [[ "$output" != *"tier-unknown"* ]]
}

# Writes the aiusage feed the budget block reads: 5-hour %, weekly %, and how
# far off the weekly reset is. The third argument is seconds of week REMAINING,
# because that is what the human's reserve drains against — a test that pinned
# an absolute stamp would start passing for the wrong reason, then stop.
stub_usage() { # <5h %> <week %> <seconds of week left>
  # The path is the one `setup`'s config names; the file simply does not exist
  # until a case calls this, which is how the default is a stated unknown.
  printf '%s\t%s\t0\t%s\tstub\n' "$1" "$2" "$(($(date +%s) + $3))" >"$TMP/usage.tsv"
}

# ── the budget verdict, which is the fixer gate ───────────────────────────────
# A gate that refuses everything is invisible: its "no" is the same word as a
# correct "no", and the path behind it simply never runs. So the case that
# matters most here is the plain affirmative, and it is written first — the
# refusals below it are only worth pinning once something can get through.

@test "the two dials and the ceiling are still the ones the docs state" {
  # The README's budget section quotes these three numbers, and the verdict is
  # unreadable without them. A tuned dial is a fine change; a tuned dial the
  # doc still states the old value for is the drift this pins.
  #
  # Both SIDES are read, and that is the whole point: a pin that only greps the
  # defaults is re-blessed by the same edit that breaks the doc, which is a
  # check whose remedy is to update the check.
  lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -q '"ceiling": 95' "$lib" && grep -q 'ceiling` (95' "$doc"
  grep -q '"reserve": 70' "$lib" && grep -q 'reserve` (70)' "$doc"
  grep -q '"fixer": 5' "$lib" && grep -q 'fixer` (5)' "$doc"
}

@test "an early-week burst with the week mostly unspent can still afford a fixer" {
  # A sixth of the week's budget gone with 84% of its clock left. Bursty is how
  # this account is actually spent, so if this shape cannot get through, the
  # CI-RED path has no reachable caller at all.
  stub_usage 13 16 $((604800 * 84 / 100))
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixer: yes"* ]]
}

@test "a saturated 5-hour window refuses however much of the week is left" {
  # Not the same question as the week, and it outranks it: a factory that
  # saturates the rolling window at 4am rate-limits whoever sits down at 9.
  stub_usage 84 16 $((604800 * 84 / 100))
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixer: no (5h window at 84%)"* ]]
}

@test "a burst big enough to eat the human's rest of the week refuses" {
  # Half the window gone with 90% of it still to come — burst-tolerant is not
  # the same as unbounded, and the reserve is what draws that line.
  stub_usage 10 50 $((604800 * 90 / 100))
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"fixer: no (headroom"* ]]
}

@test "a spent week late in the window refuses, where the same spend early does not" {
  stub_usage 10 90 $((604800 * 10 / 100))
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: no (headroom"* ]]
  # The reserve drains with the clock, so the LAST of the week is the factory's
  # to spend if the human left it — otherwise the gate is just a later pace line.
  stub_usage 10 60 $((604800 * 10 / 100))
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: yes"* ]]
}

@test "a budget that cannot be read is a refusal, never permission" {
  # Three ways to not know, one answer. An unknown that fell through to `yes`
  # would spawn lanes on a machine whose quota nobody can see — the same
  # mistake `ci-unknown` and `tier-unknown` exist to refuse to make.
  run "$SHIFT" --dry-run   # setup() points budget.feed at a file no case wrote
  [[ "$output" == *"budget: unknown"*"fixer: no (budget unknown)"* ]]

  printf 'claude\tclaude\t0\t0\tstub\n' >"$TMP/usage.tsv"
  run "$SHIFT" --dry-run
  [[ "$output" == *"unreadable feed"*"fixer: no (budget unknown)"* ]]

  printf '10\t50\t0\t0\tstub\n' >"$TMP/usage.tsv"
  run "$SHIFT" --dry-run
  [[ "$output" == *"weekly reset stamp unusable"*"fixer: no (budget unknown)"* ]]
}

@test "a feed value that would break the arithmetic degrades, and never to silence" {
  # `08` is the one that matters: it passes a range test, and `$((08))` is a
  # fatal base-8 error that takes the whole `budget:` line out of the log. A
  # missing line is worse than a wrong one here — the morning reads this file
  # and a row that is simply absent makes no claim it can catch.
  printf '05\t08\t0\t%s\tstub\n' "$(($(date +%s) + 500000))" >"$TMP/usage.tsv"
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget:"* ]]
  [[ "$output" != *"value too great for base"* ]]

  # A negative percentage passes a range test too, and it buys headroom.
  printf '10\t-5\t0\t%s\tstub\n' "$(($(date +%s) + 500000))" >"$TMP/usage.tsv"
  run "$SHIFT" --dry-run
  [[ "$output" == *"unreadable feed"*"fixer: no (budget unknown)"* ]]
}

@test "a reset stamp further out than the window it names is unusable, not a huge reserve" {
  # What a units change upstream (seconds → milliseconds) looks like from here.
  # Unbounded, it makes the reserve six figures and the gate permanently shut —
  # by a `no` that reads exactly like every correct `no`, which is the shape
  # this whole block exists not to be.
  printf '10\t16\t0\t9999999999\tstub\n' >"$TMP/usage.tsv"
  run "$SHIFT" --dry-run
  [[ "$output" == *"weekly reset stamp unusable"*"fixer: no (budget unknown)"* ]]
  [[ "$output" != *"headroom -"* ]]
}

@test "both thresholds are pinned AT their edge, not near it" {
  # A case at 84% and one at 13% leaves `-ge 80` and `-gt 80` indistinguishable,
  # and a gate this PR exists to make reachable should have its edge reachable
  # by a test too. Each pair straddles one comparison and nothing else.
  stub_usage 80 16 $((604800 * 84 / 100))
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: no (5h window at 80%)"* ]]
  stub_usage 79 16 $((604800 * 84 / 100))
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: yes"* ]]

  # reserve at a full week = 70, ceiling 95, so headroom = 25 - week%.
  # That edge is reachable only with left == 604800 exactly: the script
  # rejects a stamp further out than the window it names, and integer
  # division drops the reserve to 69 the moment left is 604799 — so a real
  # clock only hits it if the script's `date +%s` lands on the same second
  # the stamp was written. CI crossed a second between the two calls and
  # the gate flipped to `yes`. Freeze the clock so both read the same `now`.
  fixed_now=$(date +%s)
  printf '#!/usr/bin/env bash\necho "%s"\n' "$fixed_now" >"$TMP/bin/date"
  chmod +x "$TMP/bin/date"
  stub_usage 0 20 604800
  run "$SHIFT" --dry-run
  [[ "$output" == *"headroom 5 pts · fixer: yes"* ]]
  stub_usage 0 21 604800
  run "$SHIFT" --dry-run
  [[ "$output" == *"headroom 4 pts · fixer: no (headroom 4 pts, one fixer needs 5)"* ]]
}

# ── the four blind spots ─────────────────────────────────────────────────────

@test "a main whose latest run cannot be READ is ci-unknown, never silence" {
  stub_gh ok fail none
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ci-unknown: hausfold/perch"* ]]
  # not-red and could-not-look must not print the same thing, or a red main
  # inside a flaky window is reported by omission.
  [[ "$output" != *"CI-RED"* ]]
  # And it carries WHY: telling a blip from a rate limit is the foreman's
  # judgement, and this line is all it has to make it on.
  [[ "$output" == *"http2: client conn could not be established"* ]]
}

@test "a repo whose open PRs cannot be listed says so, and still checks its CI" {
  stub_gh ok red fail
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"prs-unknown: hausfold/perch"* ]]
  # And it carries WHY, like the other three: the foreman's only judgement on
  # any of these is whether a repeat is a story, and a rate limit, an expired
  # token and a dropped connection are the same line without it.
  [[ "$output" == *"http2: client conn could not be established"* ]]
  # An unlistable PR set must not take the CI half down with it: they are
  # independent questions about the same repo.
  [[ "$output" == *"CI-RED: hausfold/perch"* ]]
}

@test "a PR that could not be judged is tier-unknown, not queued" {
  stub_gh ok green one
  stub_tier 1
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier-unknown: hausfold/perch#7"* ]]
  # The expensive collapse: the nightshift skill tells the foreman that queued
  # rows need nothing, so an unjudged PR filed as queued is one nobody revisits.
  [[ "$output" != *"queued: hausfold/perch#7"* ]]
}

@test "a failed org listing aborts the pass instead of reporting a quiet night" {
  stub_gh fail green none
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"pass ABORTED"* ]]
  [[ "$output" != *"pass done: 0 merged"* ]]
}

@test "an empty org listing aborts too — nothing sensed is not nothing to report" {
  stub_gh empty green none
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"pass ABORTED"* ]]
  [[ "$output" != *"pass done: 0 merged"* ]]
}

# ── the notify policy, which is a judgement and therefore worth pinning ───────

@test "one unseeable repo does not card — that judgement is the foreman's" {
  stub_gh ok fail none
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [ ! -f "$TRILL_CALLS" ]
}

@test "a pass that could not run at all DOES card — the blast radius differs" {
  stub_gh fail green none
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  grep -q "pass aborted" "$TRILL_CALLS"
}

# ── the log is the handover, so it has to hold what the terminal showed ───────

@test "every line the pass printed is also in the day's log" {
  stub_gh ok fail none
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  log="$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  [ -f "$log" ]
  grep -q "ci-unknown: hausfold/perch" "$log"
}

@test "a multi-line stderr becomes one log line, because one event is one line" {
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"repo list") echo "hausfold/perch" ;;
"pr list") ;;
"run list") printf 'error: one\nerror: two\nerror: three\n' >&2; exit 1 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  log="$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  [ "$(grep -c 'ci-unknown' "$log")" -eq 1 ]
  grep -q 'ci-unknown: hausfold/perch .*error: one error: two error: three' "$log"
}

# ── the two lines that report a failed WRITE ──────────────────────────────────
# Everything above is about a pass that could not SEE. These are passes that
# saw fine and whose ACTION did not take, and they are read for the same thing:
# whether this is a repeat, and therefore a story. A merge refused because the
# branch moved under --match-head-commit is the pin working exactly as designed
# and needs nothing; one refused by a token that expired three hours ago means
# the shift has been over since then. Without the reason on the line those are
# the same night.

@test "a tier-1 PR under a live lease merges, pinned to the SHA the verdict saw" {
  # The affirmative first, for the same reason the budget suite leads with
  # `fixer: yes`: until something can get through, none of the refusals below
  # is distinguishable from a path that simply never runs.
  stub_gh ok green one
  stub_tier 0
  grant_lease
  run "$SHIFT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged: hausfold/perch#7"* ]]
  # The head SHA comes out of factory-tier's verdict line by `${verdict##*head=}`,
  # so this is the far end of the contract test/factory-tier.bats pins at its
  # source. Two files, and nothing but these two cases holding them together.
  grep -q -- "--match-head-commit deadbeef" "$GH_MERGE_CALLS"
  [[ "$output" == *"after-merge: 2 command(s) ok after 1 merge(s)"* ]]
}

@test "a merge that did not take says why, and leaves the PR open" {
  stub_gh ok green one fail
  stub_tier 0
  grant_lease
  run "$SHIFT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"merge-failed: hausfold/perch#7"* ]]
  [[ "$output" == *"Head branch was modified"* ]]
  # No card, and that is the same blast-radius judgement `ci-unknown` is made
  # on: a merge that did not happen leaves the PR exactly where the morning
  # expects to find it, which is the failure mode the whole factory promises.
  [ ! -f "$TRILL_CALLS" ]
}

@test "after-merge-failed names WHICH command stopped, and carries its stderr" {
  # `pull` failing leaves the checkouts behind origin with nothing shipped;
  # `ship` failing leaves them current with the lock edges stale. The morning's
  # move differs, and one line reading "bench pull/ship" told it neither which
  # nor why.
  stub_gh ok green one
  stub_tier 0
  grant_lease

  stub_bench fail ok
  run "$SHIFT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after-merge-failed: ./bench pull"* ]]
  [[ "$output" == *"commit or park first"* ]]

  stub_bench ok fail
  run "$SHIFT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"after-merge-failed: ./bench ship"* ]]
  [[ "$output" == *"did not move"* ]]
}
