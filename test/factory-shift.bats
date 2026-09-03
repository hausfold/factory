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
  # The whole lib/, not a named file: `common.sh` sources `ui.sh` beside it,
  # and a copy list that names one of two is a harness that reds on a file the
  # tool ships correctly.
  cp "$BATS_TEST_DIRNAME"/../lib/*.sh "$TMP/root/lib/"
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
# The stub speaks JSON because the shift asks for it: `--json` is the contract
# between the two verbs, and the human line is drawn for a person. These are the
# documents `libexec/factory-tier` actually emits — test/factory-tier.bats reads
# the real ones at their source.
stub_tier() {
  case "$1" in
  0) body='echo "{\"tier\":1,\"repo\":\"hausfold/perch\",\"number\":7,\"head\":\"deadbeef\",\"files\":1,\"lines\":2,\"reason\":null}"; exit 0' ;;
  3) body='echo "{\"tier\":null,\"repo\":\"hausfold/perch\",\"number\":7,\"head\":null,\"reason\":\"touches AGENTS.md\"}"; exit 3' ;;
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
stub_usage() { # <5h %> <week %> <seconds of week left> [seconds of 5h left]
  # The path is the one `setup`'s config names; the file simply does not exist
  # until a case calls this, which is how the default is a stated unknown.
  # Both reset stamps are bounded, so the 5-hour one defaults to a live value:
  # a case about the week says nothing about the 5-hour window and should not
  # have to restate it, and a case about the stamp itself passes the 4th arg.
  local now; now=$(date +%s)
  printf '%s\t%s\t%s\t%s\tstub\n' "$1" "$2" "$((now + ${4:-3000}))" "$((now + $3))" >"$TMP/usage.tsv"
}

# ── the budget verdict, which is the fixer gate ───────────────────────────────
# A gate that refuses everything is invisible: its "no" is the same word as a
# correct "no", and the path behind it simply never runs. So the case that
# matters most here is the plain affirmative, and it is written first — the
# refusals below it are only worth pinning once something can get through.

@test "all four budget dials are still the ones the docs state" {
  # The README's budget section quotes these four numbers, and the verdict is
  # unreadable without them. A tuned dial is a fine change; a tuned dial the
  # doc still states the old value for is the drift this pins.
  #
  # Both SIDES are read, and that is the whole point: a pin that only greps the
  # defaults is re-blessed by the same edit that breaks the doc, which is a
  # check whose remedy is to update the check.
  #
  # `window5hMax` is the fourth because it was for a long time the one dial the
  # README named no key for at all: the 5-hour bound was narrated as a fixed
  # 80%, which is the shape a retune leaves stale with nothing red.
  lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -q '"ceiling": 95' "$lib" && grep -q 'ceiling` (95' "$doc"
  grep -q '"reserve": 70' "$lib" && grep -q 'reserve` (70)' "$doc"
  grep -q '"fixer": 5' "$lib" && grep -q 'fixer` (5)' "$doc"
  grep -q '"window5hMax": 80' "$lib" && grep -qF 'window5hMax` (80)' "$doc"
  # And the claim BESIDE them, which is about a third file: the four dials are
  # absent from the starter config on purpose, the same way `scope`'s two keys
  # and `notify.command` are. Adding one to the example would otherwise make
  # that sentence wrong with nothing red.
  ex="$BATS_TEST_DIRNAME/../share/config.example.json"
  for d in ceiling reserve fixer window5hMax; do
    ! grep -q "\"$d\"" "$ex"
  done
}

@test "a fractional window5hMax is refused, not a 5-hour gate that stops firing" {
  # `[ "$p5" -ge "80.5" ]` is not an error the pass dies on — test(1) complains
  # to stderr and returns non-zero, which the `if` reads as false. So the one
  # condition that OUTRANKS the weekly half silently retires, and the shift goes
  # on spawning lanes at 99% of the rolling window. `type == "number"` was true
  # of it, which is why the check had to grow past that.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] }, "budget": { "window5hMax": 80.5 } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget thresholds must be whole numbers of percentage points"* ]]
}

@test "a fractional reserve is refused, not a budget line that vanishes" {
  # The other half of the same hole, and NOT a crash: this script runs under
  # `set -uo pipefail` and deliberately not `-e`, so `$((70.5 * left /
  # 604800))` writes an arithmetic error to stderr, skips the rest of the block
  # and lets the pass end on `pass done: 0 merged` with no `budget:` line in it
  # — which is the shape of a healthy quiet night. A nonsense policy stops at
  # validation, where the message names the key.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] }, "budget": { "reserve": 70.5 } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget thresholds must be whole numbers of percentage points"* ]]
}

@test "a budget dial outside the 0-100 window is refused too" {
  # Out of range is the same silence as a fraction, without the stderr: a
  # `window5hMax` above 100 cannot fire against a percentage the feed check has
  # already bounded at 100, so the gate is open for good.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] }, "budget": { "window5hMax": 101 } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"budget thresholds must be whole numbers of percentage points"* ]]
}

# ── the fifth way to be blind: an org listing cut off at the cap ──────────────
# `gh repo list --limit` caps what comes back rather than paging past it, so an
# org with more repos than the cap returns exactly the cap and says nothing —
# and every repo past it is unwalked in a pass that still prints a quiet night.
# That is the same shape as the four blind cases above, with one difference: the
# count can only be equalled, so a truncated org and one holding exactly that
# many are indistinguishable. It warns rather than aborting for that reason, and
# the pass goes on.

@test "an org listing that fills scope.limit says so, and the pass still runs" {
  cat >"$TMP/config.json" <<EOF
{
  "scope": { "orgs": ["hausfold"], "limit": 1 },
  "budget": { "feed": "$TMP/usage.tsv" },
  "afterMerge": { "workdir": "$TMP/root", "commands": ["./bench pull", "./bench ship"] }
}
EOF
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"listed 1 repos, the whole of scope.limit"* ]]
  [[ "$output" == *"pass done: 0 merged"* ]]
}

@test "a listing short of the cap says nothing about it" {
  # The control the case above needs: the stub lists one repo either way, so
  # without this a warning keyed on nothing at all would pass the first case.
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" != *"scope.limit"* ]]
}

@test "a scope.limit that could not cap anything is a usage error, not a pass" {
  # `--limit 0` is rejected by gh itself, so the pass would die mid-walk with a
  # stub's stderr quoted at it. Validation is where a nonsense policy stops.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"], "limit": 0 } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"scope.limit must be a positive number"* ]]
}

@test "the two scope defaults are still the ones the docs state" {
  # Same double-pin as the budget dials below: a default the README quotes is a
  # default a test reads on BOTH sides, or the edit that retunes it re-blesses
  # the check that should have caught the doc going stale.
  lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -q '"archived": false' "$lib" && grep -qF 'archived` (`false`)' "$doc"
  grep -q '"limit": 100' "$lib" && grep -qF 'limit` (100)' "$doc"
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
  stub_usage 05 08 500000
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"budget:"* ]]
  [[ "$output" != *"value too great for base"* ]]

  # A negative percentage passes a range test too, and it buys headroom.
  stub_usage 10 -5 500000
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

@test "a 5-hour reset stamp that has already passed is unusable, not a live percentage" {
  # The quieter half of the same failure. A feed that stopped hours ago still
  # parses, and the window its `5h %` measured has since rolled over — so a
  # dead 10% is handed to the test that OUTRANKS the weekly one, which is the
  # only way a stale number here reaches `yes`. Bounded only by the week, that
  # goes unnoticed until the feed is seven days old.
  stub_usage 10 16 $((604800 * 84 / 100)) -600
  run "$SHIFT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"5-hour reset stamp unusable"*"fixer: no (budget unknown)"* ]]
  [[ "$output" != *"fixer: yes"* ]]

  # Further out than the five hours it names is the units change again.
  stub_usage 10 16 $((604800 * 84 / 100)) 20000
  run "$SHIFT" --dry-run
  [[ "$output" == *"5-hour reset stamp unusable"*"fixer: no (budget unknown)"* ]]

  # And the same feed with a live stamp is the case this one is the negative
  # of — a bound that refused everything would be invisible.
  stub_usage 10 16 $((604800 * 84 / 100)) 600
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: yes"* ]]

  # Pinned AT the edge, on both sides. Freeze the clock first: the stamp and
  # the script's own `now` straddle a second otherwise, exactly as CI hit on
  # the weekly edge below.
  fixed_now=$(date +%s)
  printf '#!/usr/bin/env bash\necho "%s"\n' "$fixed_now" >"$TMP/bin/date"
  chmod +x "$TMP/bin/date"
  stub_usage 10 16 $((604800 * 84 / 100)) 18000
  run "$SHIFT" --dry-run
  [[ "$output" == *"fixer: yes"* ]]
  stub_usage 10 16 $((604800 * 84 / 100)) 18001
  run "$SHIFT" --dry-run
  [[ "$output" == *"5-hour reset stamp unusable"*"fixer: no (budget unknown)"* ]]
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

# ── notify.mode: command, the delivery path `auto` never exercises ────────────
# Every case above runs under the default `auto`, which finds the stubbed trill.
# `command` is a second path with its own argv contract, and it had no case at
# all: a mode validation names, `config print` prints, and nothing ever ran.

@test "notify.mode command runs the argv, with kind and title appended" {
  cat >"$TMP/bin/recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/notify-calls"
EOF
  chmod +x "$TMP/bin/recorder"
  cat >"$TMP/config.json" <<EOF
{
  "scope": { "orgs": ["hausfold"] },
  "budget": { "feed": "$TMP/usage.tsv" },
  "notify": { "mode": "command", "command": ["recorder", "--to", "me"] }
}
EOF
  stub_gh fail green none
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  # The user's own argv first, the event appended behind it in that order.
  grep -q -- "--to me fault factory: pass aborted" "$TMP/notify-calls"
  # And trill was not also called: the modes are exclusive, not additive.
  [ ! -f "$TRILL_CALLS" ]
}

@test "notify.mode command with nothing to run is a usage error, not a quiet night" {
  # The shape this arm exists for: `command` with an empty argv used to return
  # 0 from `notify` without sending anything, and a shift that cards nothing
  # looks exactly like a shift with nothing to card until the morning you
  # needed one.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] }, "notify": { "mode": "command" } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"notify.mode is command with an empty notify.command"* ]]
}

@test "a notify.command written as a string is refused rather than iterated" {
  # `cfg '.notify.command[]'` cannot iterate a string: jq writes an error to
  # stderr, the argv comes back empty, and `notify` returns 0. Same silence as
  # above, arrived at from the likelier typo.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] },
  "notify": { "mode": "command", "command": "notify-send" } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"notify.command must be an array of argv words"* ]]
}

@test "a notify.command whose first word is empty is refused too" {
  # The gap the three arms above left: a non-empty ARRAY holding an empty
  # STRING passed every length check, `notify` ran `"" fault <title>` into
  # `|| true`, and `doctor` reported it as `notify.command names , which is not
  # on PATH` — a sentence with a hole in it. Only argv[0] is checked, because a
  # later empty word is a legitimate empty argument.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] },
  "notify": { "mode": "command", "command": ["", "--to", "me"] } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"notify.command starts with an empty word"* ]]
}

@test "an empty notify.source is a usage error, because a rule matches on it" {
  # `trill send --source ""` is the one value that cannot be routed: a rules
  # file matches on that string, so an empty one silences this tool by making
  # it unnameable rather than by anybody deciding to.
  cat >"$TMP/config.json" <<EOF
{ "scope": { "orgs": ["hausfold"] }, "notify": { "source": "" } }
EOF
  run "$SHIFT" --dry-run
  [ "$status" -ne 0 ]
  [[ "$output" == *"notify.source must be a non-empty string"* ]]
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
  # The head SHA comes out of factory-tier's `--json` verdict, so this is the
  # far end of the contract test/factory-tier.bats pins at its source. Two
  # files, and nothing but these two cases holding them together.
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
