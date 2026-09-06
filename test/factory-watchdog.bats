#!/usr/bin/env bats
# Unit tests for `libexec/factory-watchdog` — the RUNNER: the process a live
# lease starts, which passes `factory shift` on a cadence, puts every CI-RED
# through the four fixer gates, and notices when its own passes stop landing.
#
# `factory-shift` is STUBBED, with a scripted event stream, because the contract
# between the two verbs is the `--json` events and nothing else: the shift
# suite tests the real shift, and this one tests what the runner does with what
# a shift said. The stub appends a `pass done` line to the day's log the way the
# real one does, so the heartbeat moves, and it records every call.
#
# The shape half the cases pin is the one the README's *The runner* records: a
# runner that is alive is not the same as passes that are landing, so "the log
# went quiet while the lease stayed live" is still the whole liveness signal —
# and under a runner, the way that happens is a shift that exits before its
# first line, which the `die` stub is.
#
# Three cases below are REGRESSION tests for bugs this script shipped with in
# review, and each one made the revoke unreachable rather than merely wrong —
# they are marked ⚠ and are the reason the suite exists at all:
#   • the runner's own log line resetting the mtime it reads,
#   • yesterday's log outranking today's grant stamp,
#   • a lease revoked out from under a living shift because the MACHINE slept.
#
# `trill` is stubbed and PATH is PREPENDED, so `notify`'s `command -v` finds the
# stub rather than the real binary on a developer's Mac. Several cases reach a
# `notify fault`, and a test suite is never a reason to put a card on somebody's
# screen. The stub records its calls, which makes the card POLICY — one per
# stall, re-armed by a recovery — testable rather than merely unobtrusive.
#
# The lease file is usually written directly rather than through `factory-lease
# grant`, because `grant` now spawns a real runner and a leaked one would
# outlive the test that spawned it. The cases that DO call `grant` are the ones
# whose subject is that spawn, and they stop it themselves.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`, for the flag refusal

setup() {
  TMP="$BATS_TEST_TMPDIR"
  mkdir -p "$TMP/root/libexec" "$TMP/root/lib" "$TMP/bin"
  cp "$BATS_TEST_DIRNAME/../libexec/factory-watchdog" "$TMP/root/libexec/"
  cp "$BATS_TEST_DIRNAME/../libexec/factory-lease" "$TMP/root/libexec/"
  # The whole lib/, not a named file: `common.sh` sources `ui.sh` beside it,
  # and a copy list that names one of two is a harness that reds on a file the
  # tool ships correctly.
  cp "$BATS_TEST_DIRNAME"/../lib/*.sh "$TMP/root/lib/"
  cp "$BATS_TEST_DIRNAME/../VERSION" "$TMP/root/"
  WD="$TMP/root/libexec/factory-watchdog"
  LEASECMD="$TMP/root/libexec/factory-lease"
  SHIFT="$TMP/root/libexec/factory-shift"

  export FACTORY_STATE_DIR="$TMP/state"
  # A config the suite owns, so nothing here reads the machine's own policy.
  # The thresholds stay env-driven: a 45-minute one has to be reachable in
  # seconds, and every case below sets its own pair.
  export FACTORY_CONFIG="$TMP/config.json"
  printf '{"scope":{"orgs":["hausfold"]}}\n' >"$TMP/config.json"
  mkdir -p "$FACTORY_STATE_DIR"
  export FACTORY_WATCHDOG_INTERVAL=1
  # The cadence too, and shorter than STALE in every case that shortens
  # STALE: the runner refuses a stall threshold inside its own cadence.
  export FACTORY_RUNNER_INTERVAL=1
  export FACTORY_NO_WATCHDOG=1

  PATH="$TMP/bin:$PATH"
  export PATH
  export TRILL_CALLS="$TMP/trill-calls"
  cat >"$TMP/bin/trill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRILL_CALLS"
EOF
  chmod +x "$TMP/bin/trill"
  export SHIFT_CALLS="$TMP/shift-calls"
  export SPAWN_CALLS="$TMP/spawn-calls"
  stub_shift ok
  FAKE_PID=""
  RACERS=""
}

teardown() {
  [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null || true
  # The race case starts runners that are deliberately NOT the pidfile's — two
  # of the three are meant to lose it — so the pidfile alone cannot reap them.
  # A regression there means a runner that outlives its test and goes on
  # passing underneath every case after it.
  local p
  for p in $RACERS; do
    case "$(ps -p "$p" -o command= 2>/dev/null)" in
    *factory-watchdog\ run) kill "$p" 2>/dev/null || true ;;
    esac
  done
  # Guarded the same way the script guards, and for the same reason: one case
  # below deliberately parks bats' OWN pid in that file, and a teardown that
  # trusted it would take the test runner down with it.
  if [ -s "$FACTORY_STATE_DIR/watchdog.pid" ]; then
    p=$(cat "$FACTORY_STATE_DIR/watchdog.pid")
    case "$(ps -p "$p" -o command= 2>/dev/null)" in
    *factory-watchdog\ run) kill "$p" 2>/dev/null || true ;;
    esac
  fi
}

# The scripted shift. Every mode but `die` appends a `pass done` line to the
# day's log, which is the heartbeat, and prints the events the runner reads:
#   ok        a quiet pass, budget refused (no feed), nothing red
#   red       a red default branch, budget refused — the budget gate's case
#   red-yes   a red default branch, budget says yes — the affirmative
#   unknown   one ci-unknown — the retry's case
#   abort     `pass ABORTED`, exit 1
#   after     after-merge-failed — the third retry-worthy event
#   die       exit 2 before writing anything, like a config gone invalid
#   garbage   exit 0 with stdout that is not the event stream
# Written to a private name and `mv`ed into place, because one case swaps the
# stub while the runner is calling it once a second: a `cat >` truncates first,
# and bash reading a script mid-rewrite is a stub that did neither shape.
stub_shift() { # stub_shift <mode> [head sha]
  # `-` and not `:-`: an EMPTY head is one case's whole subject, and `:-`
  # would read it as unset and hand that case a SHA.
  local head="${2-deadbeef}"
  cat >"$SHIFT.tmp" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$SHIFT_CALLS"
mode="$1"
if [ "\$mode" = die ]; then
  echo "factory: tier1.allow is empty — no PR could ever be tier 1  (in /x/config.json)" >&2
  exit 2
fi
log="\$FACTORY_STATE_DIR/shift-\$(date +%Y%m%d).log"
echo "\$(date '+%H:%M') policy: 00000000 · factory 0.0.0" >>"\$log"
echo '{"event":"policy","digest":"00000000","version":"0.0.0"}'
if [ "\$mode" = garbage ]; then echo "this is not an event"; fi
case "\$mode" in
red-yes) echo '{"event":"budget","mode":"unmetered","fixer":true}' ;;
*)       echo '{"event":"budget","mode":"metered","fixer":false,"reason":"5h window at 90%"}' ;;
esac
case "\$mode" in
red | red-yes)
  echo "\$(date '+%H:%M') CI-RED: hausfold/perch https://example.invalid/run/1" >>"\$log"
  echo '{"event":"ci-red","repo":"hausfold/perch","url":"https://example.invalid/run/1","conclusion":"failure","head":"$head","branch":"main"}'
  ;;
unknown)
  echo '{"event":"ci-unknown","repo":"hausfold/perch","stderr":"connection reset by peer"}'
  ;;
after)
  echo '{"event":"after-merge-failed","command":"./bench ship","stderr":"edge did not move"}'
  ;;
abort)
  echo "\$(date '+%H:%M') pass ABORTED: hausfold listed zero repos" >>"\$log"
  echo '{"event":"aborted","reason":"hausfold listed zero repos"}'
  exit 1
  ;;
esac
echo "\$(date '+%H:%M') pass done: 0 merged" >>"\$log"
echo '{"event":"pass-done","merged":0}'
EOF
  chmod +x "$SHIFT.tmp"
  mv "$SHIFT.tmp" "$SHIFT"
}

# A lane spawner that records its argv, and either returns at once or fails.
stub_spawner() { # stub_spawner ok|fail
  cat >"$TMP/bin/spawner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\$SPAWN_CALLS"
case "$1" in fail) echo "scruff: no such repo checkout" >&2; exit 1 ;; esac
EOF
  chmod +x "$TMP/bin/spawner"
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"command":["spawner"]}}\n' >"$TMP/config.json"
}

# A lease expiring $1 seconds from now, granted $2 seconds ago.
lease() {
  printf '%s\t1\t%s\n' "$(($(date +%s) + $1))" "$(($(date +%s) - $2))" \
    >"$FACTORY_STATE_DIR/lease"
}

stamp() { date -r "$1" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$1" '+%Y%m%d%H%M.%S'; }

# Today's shift log, last touched $1 seconds ago.
log_aged() {
  local f="$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  echo "09:15 pass done: 0 merged" >"$f"
  touch -t "$(stamp "$(($(date +%s) - $1))")" "$f"
}

today_log() { printf '%s\n' "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"; }

# A process that answers to the name the pidfile claims, without being a real
# runner. `is_watchdog` matches a command ENDING in `factory-watchdog run`, so
# the stub has to be a script of that name invoked with that verb — an
# `exec -a` rename cannot produce it, since the sleep duration would follow.
fake_runner() {
  cat >"$TMP/bin/factory-watchdog" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
  chmod +x "$TMP/bin/factory-watchdog"
  "$TMP/bin/factory-watchdog" run &
  FAKE_PID=$!
  printf '%s\n' "$FAKE_PID" >"$FACTORY_STATE_DIR/watchdog.pid"
}

# Wait up to 25s for a predicate, so nothing here races a 1s tick — nor the
# deliberately over-long `sleep`s the suspend cases install. `until_ok_long`
# is a minute, for the one case whose subject is a string of naps.
until_ok() { until_n 250 "$@"; }
until_ok_long() { until_n 600 "$@"; }
until_n() {
  local n="$1" i=0
  shift
  while [ $i -lt "$n" ]; do
    if "$@"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# The number of times the stubbed shift has been called, as a predicate for
# `until_ok`: `$(wc -l …)` written into until_ok's own arguments would be
# expanded once, before the first attempt.
shift_calls_reach() { lines_reach "$SHIFT_CALLS" "$1"; }
lines_reach() { [ -s "$1" ] && [ "$(wc -l <"$1" | tr -d ' ')" -ge "$2" ]; }
shift_calls() { if [ -s "$SHIFT_CALLS" ]; then wc -l <"$SHIFT_CALLS" | tr -d ' '; else echo 0; fi; }

# How many of the NAMED pids are live runners — never a `pgrep -f
# "factory-watchdog run"` over the process table, which is a different and
# wrong question. A runner forks a subshell for every command substitution in
# its loop, and a forked child inherits its parent's argv verbatim: `quiet=$(
# check "$slept")` alone runs a whole `factory-lease` and a `jq` while a second
# process with a byte-identical command line sits in the table. Any pattern
# match sampling that instant counts the one correct runner twice. That phantom
# is what made the race case below fail on a loaded runner while the claim it
# tests was doing exactly the right thing — and it fired more often the busier
# the machine, because the fork lives for as long as the tick takes.
#
# Asking `ps` about a pid we started answers the question the case actually
# has: of the processes THIS test spawned, how many are still runners.
runners_alive() {
  local pid n=0
  for pid in "$@"; do
    case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *factory-watchdog\ run) n=$((n + 1)) ;;
    esac
  done
  printf '%s\n' "$n"
}

# The predicate form, because `until_ok` re-runs its argv: a `$(runners_alive
# ...)` written into until_ok's own arguments would be expanded once, before
# the first attempt, and every retry would re-test the first answer.
runner_count_is() {
  local want="$1"; shift
  [ "$(runners_alive "$@")" -eq "$want" ]
}

# ── nothing to watch ──────────────────────────────────────────────────────────

@test "no lease at all: nothing to watch, not a stalled shift" {
  run "$WD" once
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live lease"* ]]
}

@test "expired lease: nothing to watch — the shift ended the ordinary way" {
  lease -600 43200
  log_aged 7200
  run "$WD" once
  [ "$status" -eq 1 ]
  [[ "$output" == *"no live lease"* ]]
}

# ── the runner: a live lease passes on its own ───────────────────────────────
# The affirmative first, for the reason the shift suite leads with `fixer:
# yes`: until a pass can land with no agent involved, none of the refusals and
# gates below is distinguishable from a path that never runs.

@test "a live lease and the runner produce pass done lines on the cadence, with no agent involved" {
  lease 3600 5
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok shift_calls_reach 3
  kill $pid 2>/dev/null || true
  # Three passes, each of them `factory shift --json` and nothing else — the
  # runner reads events, never the human line.
  [ "$(shift_calls)" -ge 3 ]
  [ "$(sort -u "$SHIFT_CALLS")" = "--json" ]
  [ "$(grep -c "pass done" "$(today_log)")" -ge 3 ]
}

@test "the first pass lands within seconds of the grant, not one cadence later" {
  # `grant` starts the runner; a user who typed it should see a pass now, and
  # a runner launchd restarted after a crash has a gap to close.
  unset FACTORY_NO_WATCHDOG
  FACTORY_RUNNER_INTERVAL=600 "$LEASECMD" grant 30m >/dev/null
  until_ok shift_calls_reach 1
  [ "$(shift_calls)" -ge 1 ]
  "$LEASECMD" revoke >/dev/null
}

@test "a pass runs only under a live lease, and the runner leaves when the lease ends" {
  # The ordinary end of a timed shift: the log's last line says the shift is
  # over, not merely that a pass happened to be its last.
  lease 3 5
  run "$WD" run
  [ "$status" -eq 0 ]
  grep -q "pass done" "$(today_log)"
  grep -q "shift-over: lease ended" "$(today_log)"
  # And every call the stub saw was made while the lease stood: the runner
  # asks the lease at each pass, not once at start.
  [ "$(shift_calls)" -ge 1 ]
  [ "$(shift_calls)" -le 4 ]
}

@test "a runner that never saw a lease adds nothing to the log" {
  # Started after the expiry — launchd restarting it, or `ensure` racing a
  # revoke. Nothing passed, so nothing is over.
  lease 1 3600
  log_aged 60
  sleep 2
  run "$WD" run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  ! grep -q "shift-over" "$(today_log)"
  [ "$(shift_calls)" -eq 0 ]
}

@test "a runner with no shift to run refuses to be one" {
  # A live lease under a process that could pass nothing is exactly the
  # standing grant the runner exists to refuse — and it would otherwise sit
  # there reporting itself alive.
  lease 3600 5
  chmod -x "$SHIFT"
  run --separate-stderr "$WD" run
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"cannot run"*"factory-shift"* ]]
  [ ! -e "$FACTORY_STATE_DIR/watchdog.pid" ]
}

# ── the retry: once, at the next tick ────────────────────────────────────────
# A pass that could not see gets one more pass five minutes later, not twenty.
# Once, because a second unknown is a story for the morning and not a loop; and
# at the next TICK rather than at once, because the blip that made a `gh` call
# fail is usually still there a second later.

@test "an unknown line earns one more pass at the next tick, and only one" {
  lease 3600 5
  stub_shift unknown
  # A long cadence, so the second call can only be the retry.
  FACTORY_RUNNER_INTERVAL=60 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok shift_calls_reach 2
  # Three more ticks: a third call would be a retry of the retry.
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(shift_calls)" -eq 2 ]
  grep -q "pass-retry: ci-unknown" "$(today_log)"
  [ "$(grep -c "pass-retry" "$(today_log)")" -eq 1 ]
}

@test "an aborted pass and a failed after-merge hook are retried the same way" {
  lease 3600 5
  stub_shift abort
  FACTORY_RUNNER_INTERVAL=60 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok shift_calls_reach 2
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(shift_calls)" -eq 2 ]
  grep -q "pass-retry: aborted" "$(today_log)"

  rm -f "$SHIFT_CALLS"
  rm -f "$(today_log)"
  stub_shift after
  FACTORY_RUNNER_INTERVAL=60 "$WD" run >/dev/null 2>&1 &
  pid=$!
  until_ok shift_calls_reach 2
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(shift_calls)" -eq 2 ]
  grep -q "pass-retry: after-merge-failed" "$(today_log)"
}

@test "a quiet pass is not retried" {
  lease 3600 5
  FACTORY_RUNNER_INTERVAL=60 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok shift_calls_reach 1
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(shift_calls)" -eq 1 ]
  ! grep -q "pass-retry" "$(today_log)"
}

# ── the four fixer gates ──────────────────────────────────────────────────────
# Each case below is written so that deleting its gate fails it. These were a
# skill's prose once — a threshold no test could reach, whose refusal was the
# same word as a correct refusal.

@test "a CI-RED clears all four gates and spawns through fixer.command with repo, branch and url" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes 9c2e1f0
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  # Waited on the LOG line, which lands after the spawner returns: waiting on
  # the spawner's own record races the `note` that follows it.
  until_ok grep -qs "fixer-spawned" "$(today_log)"
  kill $pid 2>/dev/null || true
  # Three words, in this order: the lane is handed facts, not a JSON document.
  [ "$(head -1 "$SPAWN_CALLS")" = "hausfold/perch main https://example.invalid/run/1" ]
  grep -q "fixer-spawned: hausfold/perch 9c2e1f0" "$(today_log)"
}

@test "gate 1 — no fixer.command configured: the red is reported and the skip says why" {
  lease 3600 5
  stub_shift red-yes
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  grep -q "CI-RED: hausfold/perch" "$(today_log)"
  grep -q "fixer-skipped: hausfold/perch — no fixer.command configured" "$(today_log)"
  ! grep -q "fixer-spawned" "$(today_log)"
  [ ! -e "$SPAWN_CALLS" ]
}

@test "gate 2 — the same head SHA never gets a second lane, however many passes report it" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes 9c2e1f0
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok shift_calls_reach 3
  kill $pid 2>/dev/null || true
  [ "$(wc -l <"$SPAWN_CALLS" | tr -d ' ')" -eq 1 ]
  [ "$(grep -c "fixer-spawned: hausfold/perch 9c2e1f0" "$(today_log)")" -eq 1 ]
  grep -q "fixer-skipped: hausfold/perch — a lane was already spawned for 9c2e1f0" "$(today_log)"
}

@test "gate 2 reads every shift log, not tonight's — a red that stood across midnight does not get a lane a day" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes 9c2e1f0
  local old="$FACTORY_STATE_DIR/shift-20260828.log"
  echo "23:50 fixer-spawned: hausfold/perch 9c2e1f0 — lane on main for https://example.invalid/run/1" >"$old"
  touch -t "$(stamp "$(($(date +%s) - 86400))")" "$old"
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ ! -e "$SPAWN_CALLS" ]
  grep -q "already spawned for 9c2e1f0" "$(today_log)"
}

@test "gate 3 — at most fixer.cap lanes per repo per day, and a new SHA past the cap says so" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes cccccc3
  # Two lanes already today, for two earlier failures.
  printf '01:00 fixer-spawned: hausfold/perch aaaaaa1 — lane on main for x\n02:00 fixer-spawned: hausfold/perch bbbbbb2 — lane on main for y\n' >"$(today_log)"
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ ! -e "$SPAWN_CALLS" ]
  grep -q "fixer-skipped: hausfold/perch — 2 lane(s) already today, fixer.cap is 2" "$(today_log)"
}

@test "gate 3 counts the repo, not the night — another repo's lanes are not this one's" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes cccccc3
  printf '01:00 fixer-spawned: hausfold/pounce aaaaaa1 — lane on main for x\n02:00 fixer-spawned: hausfold/pounce bbbbbb2 — lane on main for y\n' >"$(today_log)"
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -qs "fixer-spawned: hausfold/perch" "$(today_log)"
  kill $pid 2>/dev/null || true
  grep -q "fixer-spawned: hausfold/perch cccccc3" "$(today_log)"
}

@test "gate 3 is the policy's number — fixer.cap 1 stops at one" {
  lease 3600 5
  stub_spawner ok
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"command":["spawner"],"cap":1}}\n' >"$TMP/config.json"
  stub_shift red-yes cccccc3
  printf '01:00 fixer-spawned: hausfold/perch aaaaaa1 — lane on main for x\n' >"$(today_log)"
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ ! -e "$SPAWN_CALLS" ]
  grep -q "1 lane(s) already today, fixer.cap is 1" "$(today_log)"
}

@test "gate 4 — a budget that said no is quoted, and no lane is spawned" {
  lease 3600 5
  stub_spawner ok
  stub_shift red
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ ! -e "$SPAWN_CALLS" ]
  # The reason comes off the budget EVENT, not the human line.
  grep -q "fixer-skipped: hausfold/perch — budget: 5h window at 90%" "$(today_log)"
}

@test "a spawner that fails is fixer-failed with its stderr, carded, and counted toward nothing" {
  lease 3600 5
  stub_spawner fail
  stub_shift red-yes 9c2e1f0
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok lines_reach "$SPAWN_CALLS" 2
  kill $pid 2>/dev/null || true
  grep -q "fixer-failed: hausfold/perch 9c2e1f0 — fixer.command exited 1: scruff: no such repo checkout" "$(today_log)"
  ! grep -q "fixer-spawned" "$(today_log)"
  grep -q "fixer lane for hausfold/perch did not start" "$TRILL_CALLS"
  # Nothing was spawned, so the next pass tries again rather than reading the
  # failure as a lane already there.
  [ "$(wc -l <"$SPAWN_CALLS" | tr -d ' ')" -ge 2 ]
}

@test "a red whose head SHA was not reported is skipped, not spawned every pass" {
  lease 3600 5
  stub_spawner ok
  stub_shift red-yes ""
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "fixer-skipped" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ ! -e "$SPAWN_CALLS" ]
  grep -q "head SHA was not reported" "$(today_log)"
}

# ── a pass that could not run at all ─────────────────────────────────────────

@test "a shift that exits before writing anything is pass-failed with its stderr" {
  lease 3600 5
  stub_shift die
  FACTORY_RUNNER_INTERVAL=60 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "pass-failed" "$(today_log)"
  sleep 2
  kill $pid 2>/dev/null || true
  grep -q "pass-failed: factory shift exited 2 before a pass could run — factory: tier1.allow is empty" "$(today_log)"
  # Not retried: a config that cannot be read at 02:00 cannot be read at 02:05.
  ! grep -q "pass-retry" "$(today_log)"
  [ "$(shift_calls)" -eq 1 ]
}

@test "a shift whose --json output is not the event stream is pass-failed, not a quiet zero of every count" {
  lease 3600 5
  stub_shift garbage
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "pass-failed" "$(today_log)"
  kill $pid 2>/dev/null || true
  grep -q "pass-failed: factory shift's --json output could not be read" "$(today_log)"
}

# ── the heartbeat ─────────────────────────────────────────────────────────────

@test "live lease, recent pass, runner up: alive" {
  lease 3600 3600
  log_aged 300
  fake_runner
  run "$WD" once
  [ "$status" -eq 0 ]
  [[ "$output" == *"shift alive"* ]]
  [[ "$output" == *"5m ago"* ]]
}

@test "live lease and a recent pass but NO runner is its own fault, not alive" {
  # `grant` spawns the runner with all output discarded, so a lost exec bit is
  # otherwise silent — and `doctor` carries this line.
  lease 3600 3600
  log_aged 300
  run "$WD" once
  [ "$status" -eq 4 ]
  [[ "$output" == *"NO RUNNER"* ]]
}

@test "once --json names the runner's pid under runnerPid" {
  lease 3600 3600
  log_aged 300
  fake_runner
  run "$WD" once --json
  [ "$status" -eq 0 ]
  [ "$(jq -r .state <<<"$output")" = alive ]
  [ "$(jq -r .runnerPid <<<"$output")" = "$FAKE_PID" ]
}

@test "live lease, log quiet past the stale threshold: STALLED" {
  lease 21600 3600
  log_aged 3600
  run "$WD" once
  [ "$status" -eq 3 ]
  [[ "$output" == *"STALLED"* ]]
  [[ "$output" == *"60m"* ]]
}

@test "a pass still short of the threshold is not a stall" {
  lease 21600 3600
  log_aged 2400
  fake_runner
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "the NEWEST log is the heartbeat, not the first one found" {
  lease 21600 3600
  local old="$FACTORY_STATE_DIR/shift-20260828.log"
  echo "23:50 pass done: 0 merged" >"$old"
  touch -t "$(stamp "$(($(date +%s) - 86400))")" "$old"
  log_aged 120
  fake_runner
  run "$WD" once
  [ "$status" -eq 0 ]
}

# ── ⚠ regression: yesterday's log must not outrank today's grant ──────────────

@test "⚠ a fresh grant with only an old log is alive, not instantly dead" {
  # Logs are per-day and never swept. Reading the newest log ALONE meant that
  # on every night after the first, `grant` spawned a runner that revoked the
  # lease before its first pass could write anything.
  local old="$FACTORY_STATE_DIR/shift-20260828.log"
  echo "23:50 pass done: 0 merged" >"$old"
  touch -t "$(stamp "$(($(date +%s) - 72000))")" "$old"
  lease 43200 30
  fake_runner
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "no log yet, lease just granted: alive" {
  lease 43200 60
  fake_runner
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "no log yet, lease granted an hour ago: STALLED" {
  # A runner that died before its first pass leaves no log to say so.
  lease 43200 3600
  run "$WD" once
  [ "$status" -eq 3 ]
  [[ "$output" == *"STALLED"* ]]
}

# ── ⚠ regression: the runner's own lines are not a heartbeat ──────────────────

@test "⚠ a shift that cannot start reaches DEAD and revokes, despite the runner logging every pass" {
  # `note` appends to the same file whose mtime IS the heartbeat. Without the
  # mtime being restored, every `pass-failed` line — one per cadence, all
  # night — reset quiet to zero, and a lease stood forever under a shift that
  # could not run, with a named line every twenty minutes reading as a pass.
  # Same bug the foreman-era `foreman-stalled` line had, one layer closer.
  stub_shift die
  FACTORY_STALE=2 FACTORY_DEAD=6 lease 21600 60
  log_aged 3
  FACTORY_STALE=2 FACTORY_DEAD=6 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test ! -f "$FACTORY_STATE_DIR/lease"
  kill $pid 2>/dev/null || true
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "pass-failed" "$(today_log)"
  grep -q "shift-dead" "$(today_log)"
  # The alternation the bug produced: one stall line, and never a resume, since
  # nothing ever landed a real pass.
  [ "$(grep -c "shift-stalled" "$(today_log)")" -eq 1 ]
  ! grep -q "shift-resumed" "$(today_log)"
}

@test "a pass landing after a stall is shift-resumed, and re-arms the card" {
  # The stub is switched from `die` to `ok` mid-run: the runner reads the
  # script fresh on every pass, so the stall the first shape caused is
  # recovered from by the second.
  stub_shift die
  FACTORY_STALE=2 FACTORY_DEAD=30 lease 21600 60
  log_aged 1
  FACTORY_STALE=2 FACTORY_DEAD=30 FACTORY_RUNNER_INTERVAL=1 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "shift-stalled" "$(today_log)"
  stub_shift ok
  until_ok grep -q "shift-resumed" "$(today_log)"
  kill $pid 2>/dev/null || true
  [ -f "$FACTORY_STATE_DIR/lease" ]
  [ "$(wc -l <"$TRILL_CALLS" | tr -d ' ')" -eq 1 ]
}

# ── what `run` does about a stall ─────────────────────────────────────────────

@test "a stall past DEAD revokes the lease and cards it" {
  stub_shift die
  lease 21600 10800
  log_aged 7200
  run "$WD" run
  [ "$status" -eq 3 ]
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "shift-dead" "$(today_log)"
  grep -q "lease revoked (it stood until" "$(today_log)"
  grep -q "fault" "$TRILL_CALLS"
}

@test "an indefinite lease whose passes stopped is revoked too, and the line says it was indefinite" {
  # The clock never bounded an indefinite lease; this is what does.
  stub_shift die
  printf 'never\t1\t%s\n' "$(($(date +%s) - 10800))" >"$FACTORY_STATE_DIR/lease"
  log_aged 7200
  run "$WD" run
  [ "$status" -eq 3 ]
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "shift-dead: .*lease revoked (it was indefinite)" "$(today_log)"
}

@test "a stall short of DEAD says so but leaves the lease standing" {
  # The distinction the two thresholds exist for: one pass hanging inside a
  # `gh` call may still return, and revoking under it turns a recoverable blip
  # into a shift that needs a person.
  stub_shift die
  lease 21600 3600
  log_aged 3600
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  # Waited on the CARD, not the log line: `note` runs first, so polling the log
  # would race the `notify` that follows it and kill the process between them.
  until_ok test -s "$TRILL_CALLS"
  kill $pid 2>/dev/null || true
  grep -q "shift-stalled" "$(today_log)"
  [ -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "fault" "$TRILL_CALLS"
}

@test "the stall card fires once, not once per tick" {
  stub_shift die
  lease 21600 3600
  log_aged 3600
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test -s "$TRILL_CALLS"
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(wc -l <"$TRILL_CALLS")" -eq 1 ]
}

# ── ⚠ regression: a sleeping Mac is not a stalled shift ───────────────────────

# One "suspended machine" per line in $FACTORY_STATE_DIR/.naps, consumed in
# order, keyed on the runner's own tick so the suite's sub-second waits never
# eat one.
stub_sleep() {
  printf '%s\n' "$@" >"$FACTORY_STATE_DIR/.naps"
  cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = 1 ] && [ -s "$FACTORY_STATE_DIR/.naps" ]; then
  nap=$(head -1 "$FACTORY_STATE_DIR/.naps")
  tail -n +2 "$FACTORY_STATE_DIR/.naps" >"$FACTORY_STATE_DIR/.naps.tmp"
  mv "$FACTORY_STATE_DIR/.naps.tmp" "$FACTORY_STATE_DIR/.naps"
  exec /bin/sleep "$nap"
fi
exec /bin/sleep "$1"
EOF
  chmod +x "$TMP/bin/sleep"
}

@test "⚠ a suspend is discounted, not counted against the shift" {
  # Quiet time is measured in seconds this process was AWAKE for. A machine
  # asleep past DEAD wakes to a stale log through nobody's fault — the runner
  # was not running either — and a lease revoked out from under a shift that
  # would have passed on waking is the failure this script would be
  # introducing rather than fixing.
  # A 12s nap against DEAD=10: at the kill, two seconds after the nap is
  # noted, the wall clock is past DEAD and awake time is under STALE. The gap
  # between those two is what a loaded runner gets to be slow in — under a
  # runner passing every tick, each tick costs a few forks more than the
  # poller's did, and a 2s margin here failed once on a busy machine.
  stub_shift die
  stub_sleep 12
  lease 21600 60
  log_aged 1
  FACTORY_STALE=4 FACTORY_DEAD=10 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "machine-slept" "$(today_log)"
  sleep 2
  kill $pid 2>/dev/null || true
  # Wall clock is past DEAD; awake time is not, so nothing was revoked.
  [ -f "$FACTORY_STATE_DIR/lease" ]
  ! grep -q "shift-dead" "$(today_log)"
}

@test "⚠ repeated suspends still let a shift that cannot run reach DEAD" {
  # The bug the discount replaced: a grace WINDOW re-armed on every jump, so a
  # laptop that suspends and wakes all night — the documented default, with
  # `haus.power.lidAwake` off — renewed it faster than it expired. A shift that
  # genuinely could not run then kept its lease until morning and never even
  # drew a card.
  #
  # The numbers leave room for a loaded machine: the first check comes AFTER a
  # pass now, and under a nix shell that pass is a dozen forks — with the log
  # a second old and DEAD at 3, one slow first tick revoked before the first
  # nap was ever taken, and the case failed on the `machine-slept` line it
  # never had a chance to write. Six awake seconds is the budget instead, and
  # ten naps of four seconds is more than enough wall clock to get there.
  stub_shift die
  stub_sleep 4 4 4 4 4 4 4 4 4 4
  lease 21600 60
  log_aged 0
  FACTORY_STALE=3 FACTORY_DEAD=6 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok_long test ! -f "$FACTORY_STATE_DIR/lease"
  kill $pid 2>/dev/null || true
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "machine-slept" "$(today_log)"
  grep -q "shift-dead" "$(today_log)"
}

# ── the pidfile, and the wiring `factory-lease` depends on ────────────────────

@test "a second run is a no-op while one is already running" {
  lease 21600 3600
  log_aged 60
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test -s "$FACTORY_STATE_DIR/watchdog.pid"
  run "$WD" run
  [ "$status" -eq 0 ]
  [[ "$output" == *"already running"* ]]
  kill $pid 2>/dev/null || true
}

@test "⚠ a stale pidfile is not a licence to signal whatever now holds that pid" {
  # The trap only clears the pidfile on a clean exit; a SIGKILL, a panic or a
  # reboot leaves it, and PIDs restart low after one. `$$` here is bats itself
  # — very much a live process, and very much not a runner.
  lease 21600 3600
  log_aged 60
  printf '%s\n' "$$" >"$FACTORY_STATE_DIR/watchdog.pid"
  run "$WD" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  [ ! -f "$FACTORY_STATE_DIR/watchdog.pid" ]
  # And bats is still here to assert it.
  kill -0 $$
}

@test "a stale pidfile does not read as a runner that is up" {
  lease 21600 3600
  log_aged 60
  printf '%s\n' "$$" >"$FACTORY_STATE_DIR/watchdog.pid"
  run "$WD" once
  [ "$status" -eq 4 ]
  [[ "$output" == *"NO RUNNER"* ]]
}

@test "ensure starts a runner when a live lease has lost one" {
  # `grant` establishes the invariant once; a runner can still be lost to a
  # reboot or an OOM kill. On a launchd machine that is launchd's job; anywhere
  # else, this is the verb `doctor`'s NO RUNNER line points at.
  lease 21600 60
  log_aged 30
  run "$WD" once
  [ "$status" -eq 4 ]
  run "$WD" ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"runner up"* ]]
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "ensure starts nothing when there is no lease to watch" {
  run "$WD" ensure
  [ "$status" -eq 1 ]
  [ ! -f "$FACTORY_STATE_DIR/watchdog.pid" ]
}

@test "⚠ a claim it could not write publishes nothing, not an empty pidfile" {
  # An empty pidfile is not inert. `runner_pid` reads it as nothing-alive, so
  # the next `run` deletes it and claims it — and if what it deleted was a live
  # runner's claim caught mid-write, that is a duplicate runner started on top
  # of one, which `revoke` cannot stop because it only ever stops the pid the
  # file names. So the claim writes the pid to a private name and hardlinks it
  # into place: `watchdog.pid` never exists while empty.
  #
  # The window itself is one preemption between a create and a write, which no
  # suite can schedule. A write that CANNOT land makes the same claim testable:
  # either the pid is published or nothing is. Under an O_EXCL create the file
  # is created before the write that fails, and the leftover is what the next
  # `run` would evict a live runner over.
  # The lease is EXPIRED on purpose. The claim runs before any lease is read,
  # so nothing here is weakened by it — but a regression that wrongly claims
  # then finds nothing to watch and exits, where a live lease would leave it
  # running and HANG this case rather than fail it.
  lease -600 43200
  log_aged 7200
  run bash -c 'ulimit -f 0 2>/dev/null || exit 111; exec "$1" run' _ "$WD"
  [ "$status" -ne 111 ] || skip "this shell cannot set RLIMIT_FSIZE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not claim"* ]]
  [ ! -e "$FACTORY_STATE_DIR/watchdog.pid" ]
}

@test "⚠ two simultaneous grants leave exactly one runner" {
  # The pidfile is claimed by hardlinking a file that already holds the pid,
  # not by a read-then-write: the loser of a read-then-write became an orphan
  # `revoke` could not see, still holding a trap that would delete its
  # successor's pidfile.
  #
  # Counted over the three pids started here, and WAITED for rather than slept
  # at. The fixed second this used to take assumed the losers had already
  # exited, which a loaded runner need not honour; the count can only ever
  # FALL, since nothing here starts a fourth, so "reaches one" and "settles at
  # one" are the same statement. Two runners that stay alive — the bug this
  # case exists for — still fail it, after `until_ok` has given them 25s.
  unset FACTORY_NO_WATCHDOG
  lease 21600 60
  log_aged 30
  local owner
  "$WD" run >/dev/null 2>&1 & RACERS="$!"
  "$WD" run >/dev/null 2>&1 & RACERS="$RACERS $!"
  "$WD" run >/dev/null 2>&1 & RACERS="$RACERS $!"
  until_ok test -s "$FACTORY_STATE_DIR/watchdog.pid"
  until_ok runner_count_is 1 $RACERS
  # And the survivor is the one the pidfile names, with the file still there: a
  # loser exiting on the old read-then-write held a trap that deleted its
  # successor's pidfile, which leaves exactly one runner and no claim on it.
  [ -s "$FACTORY_STATE_DIR/watchdog.pid" ]
  owner=$(cat "$FACTORY_STATE_DIR/watchdog.pid")
  runner_count_is 1 "$owner"
  case " $RACERS " in *" $owner "*) ;; *) false ;; esac
}

@test "grant starts a runner and revoke stops it" {
  # The invariant that makes this structural rather than a step anyone could
  # forget: a live lease always has a runner.
  unset FACTORY_NO_WATCHDOG
  "$LEASECMD" grant 30m >/dev/null
  until_ok test -s "$FACTORY_STATE_DIR/watchdog.pid"
  local pid
  pid=$(cat "$FACTORY_STATE_DIR/watchdog.pid")
  kill -0 "$pid"
  "$LEASECMD" revoke >/dev/null
  until_ok test ! -f "$FACTORY_STATE_DIR/watchdog.pid"
  until_ok eval "! kill -0 $pid 2>/dev/null"
  ! kill -0 "$pid" 2>/dev/null
}

@test "stop removes the pidfile and reports when nothing was running" {
  run "$WD" stop
  [ "$status" -eq 0 ]
  [[ "$output" == *"not running"* ]]
  [ ! -f "$FACTORY_STATE_DIR/watchdog.pid" ]
}

@test "usage on no argument" {
  run "$WD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"factory watchdog once"* ]]
  run "$WD" once please
  [ "$status" -eq 2 ]
}

@test "an unknown flag is refused on fd 2, not ignored" {
  lease 3600 0
  run --separate-stderr "$WD" once --jsno
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown flag '--jsno'"* ]]
}

# ── ⚠ an environment override may shorten a threshold, never lengthen it ─────
# `FACTORY_STALE`, `FACTORY_DEAD`, `FACTORY_WATCHDOG_INTERVAL` and
# `FACTORY_RUNNER_INTERVAL` exist so this suite can reach a 45-minute threshold
# in seconds. The runner inherits the environment of whoever ran `lease grant`,
# so a variable that could LENGTHEN `dead` was a lease able to stand after its
# passes stopped, one that could lengthen the cadence was a night of fewer
# passes than the policy says, and `config print`'s rows were not what was in
# force.

@test "⚠ an override longer than the policy's threshold is refused, not obeyed" {
  lease 3600 0
  log_aged 1
  FACTORY_DEAD=999999 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"may only shorten watchdog.dead (5400s)"* ]]
  FACTORY_STALE=2701 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"may only shorten watchdog.stale"* ]]
  FACTORY_WATCHDOG_INTERVAL=301 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"may only shorten watchdog.interval"* ]]
  FACTORY_RUNNER_INTERVAL=1201 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"may only shorten runner.interval (1200s)"* ]]
}

@test "an override that is not a whole number of seconds is refused too" {
  lease 3600 0
  log_aged 1
  FACTORY_DEAD=5400.5 run "$WD" once
  [ "$status" -eq 2 ]
  FACTORY_DEAD=0 run "$WD" once
  [ "$status" -eq 2 ]
  # Past 64-bit, the refusal is the whole answer: no `[: integer expression
  # expected` from a comparison that ran before the length was checked.
  FACTORY_DEAD=99999999999999999999999 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" != *"integer expression"* ]]
  [[ "$output" == *"may only shorten"* ]]
}

@test "a grant whose runner refused to start says so, rather than ✓ over nothing" {
  # `grant` discards `ensure`'s report, and used to discard its refusal with
  # it: an override the runner may not honour left a ✓ lease with no runner
  # and nothing on screen to say so until `watchdog once`.
  unset FACTORY_NO_WATCHDOG
  FACTORY_DEAD=999999 run "$LEASECMD" grant 30m
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: tier 1 until"* ]]
  [[ "$output" == *"runner did not start"* ]]
  [[ "$output" == *"may only shorten watchdog.dead"* ]]
  [ ! -s "$FACTORY_STATE_DIR/watchdog.pid" ]
  "$LEASECMD" revoke >/dev/null
}

@test "a shortened dead under an unshortened stale is refused — it would revoke before it warned" {
  lease 3600 0
  log_aged 1
  FACTORY_DEAD=60 run "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"not greater than the stale threshold (2700)"* ]]
}

@test "a shortened stale under an unshortened cadence is refused — it would call every gap between passes a stall" {
  lease 3600 0
  log_aged 1
  run env -u FACTORY_RUNNER_INTERVAL FACTORY_STALE=2 FACTORY_DEAD=6 "$WD" once
  [ "$status" -eq 2 ]
  [[ "$output" == *"not greater than the pass cadence (1200)"* ]]
}

@test "an override equal to the policy's number is the policy's number" {
  # The boundary, so the check reads `-le` and not `-lt`: a suite that pins
  # the documented default through the env is not lengthening anything.
  lease 3600 0
  log_aged 1
  FACTORY_DEAD=5400 run "$WD" once
  [ "$status" -eq 4 ]   # a live lease, no runner — the override was accepted
}

# The same double-pin the scope and budget defaults carry, one suite over: the
# README quotes all five numbers, so a retune that only edits the code would
# otherwise leave the manual saying 45 and 90 with nothing red.
@test "the watchdog, runner and fixer defaults are still the ones the README states" {
  lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -q '"stale": 2700' "$lib" && grep -qF '`watchdog.stale`, 2700' "$doc"
  grep -q '"dead": 5400' "$lib" && grep -qF '`watchdog.dead`, 5400' "$doc"
  grep -q '"interval": 300' "$lib" && grep -qF '`watchdog.interval` (300' "$doc"
  grep -q '"interval": 1200' "$lib" && grep -qF '`runner.interval` (1200' "$doc"
  grep -q '"cap": 2' "$lib" && grep -qF '`fixer.cap` (2)' "$doc"
  # And the starter config names none of the numbers, only the hook — the
  # same claim the budget suite pins about its dials.
  ex="$BATS_TEST_DIRNAME/../share/config.example.json"
  ! grep -q '"cap"' "$ex"
  ! grep -q '"runner"' "$ex"
  grep -q '"fixer"' "$ex"
}

@test "a fractional watchdog threshold is refused, not a death nobody notices" {
  # The budget dials' hole, one block over and worse. `[ "$quiet" -ge "5400.5" ]`
  # complains to stderr and returns non-zero, which the `if` reads as false — at
  # every tick, forever. So the breakdown this whole layer exists to notice is
  # never noticed and the lease stands until morning. `type == "number"` was
  # true of it and `> 1` was true of it; only wholeness is not.
  printf '{"scope":{"orgs":["hausfold"]},"watchdog":{"dead":5400.5}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"watchdog thresholds must be whole numbers of seconds"* ]]
}

@test "a fractional runner.interval is refused — a pass that is never due is a lease nobody exercises" {
  printf '{"scope":{"orgs":["hausfold"]},"runner":{"interval":1200.5}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"runner.interval must be a whole number of seconds"* ]]
}

@test "a stale threshold inside the pass cadence is refused at load" {
  printf '{"scope":{"orgs":["hausfold"]},"runner":{"interval":3000}}\n' >"$TMP/config.json"
  run env -u FACTORY_RUNNER_INTERVAL -u FACTORY_STALE "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"watchdog.stale must be greater than runner.interval"* ]]
}

@test "a fixer.command written as a string is refused, not run letter by letter" {
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"command":"spawner"}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"fixer.command must be an array of argv words"* ]]
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"command":[""]}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"fixer.command starts with an empty word"* ]]
}

@test "a fractional or negative fixer.cap is refused" {
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"cap":1.5}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"fixer.cap must be a whole number of lanes"* ]]
  printf '{"scope":{"orgs":["hausfold"]},"fixer":{"cap":-1}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
}

@test "a fractional tier1.maxLines is refused, and that one fails closed" {
  # The same slip where the consequence inverts: `[ "$churn" -le "2000.5" ]`
  # reads false too, so every PR is refused with a cap nobody can read printed
  # in the reason. Named beside the watchdog case because the pair is the
  # argument for checking wholeness at all — one direction of this mistake is
  # invisible and one is deafening, and the policy file cannot tell you which
  # you typed.
  printf '{"scope":{"orgs":["hausfold"]},"tier1":{"maxLines":2000.5}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"tier1.maxLines must be a whole number of lines"* ]]
}
