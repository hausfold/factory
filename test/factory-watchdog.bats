#!/usr/bin/env bats
# Unit tests for `libexec/factory-watchdog` — the layer that notices the FOREMAN
# stopped, which `factory-shift`'s own unknown-lines cannot, because writing one
# requires a pass that ran.
#
# The shape being pinned is the one the README's *When the foreman dies*
# records: a session whose loop ended in an API error, so no next wakeup was
# ever scheduled. Every case here is a variation on "the log went quiet
# while the lease stayed live", because that pair is the entire signal.
#
# Three cases below are REGRESSION tests for bugs this script shipped with in
# review, and each one made the revoke unreachable rather than merely wrong —
# they are marked ⚠ and are the reason the suite exists at all:
#   • the watchdog's own log line resetting the mtime it reads,
#   • yesterday's log outranking today's grant stamp,
#   • a lease revoked out from under a foreman because the MACHINE slept.
#
# `trill` is stubbed and PATH is PREPENDED, so `notify`'s `command -v` finds the
# stub rather than the real binary on a developer's Mac. Several cases reach a
# `notify fault`, and a test suite is never a reason to put a card on somebody's
# screen. The stub records its calls, which makes the card POLICY — one per
# stall, re-armed by a recovery — testable rather than merely unobtrusive.
#
# The lease file is usually written directly rather than through `factory-lease
# grant`, because `grant` now spawns a real poller and a leaked one would
# outlive the test that spawned it. The two cases that DO call `grant` are the
# ones whose subject is that spawn, and they stop it themselves.

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

  export FACTORY_STATE_DIR="$TMP/state"
  # A config the suite owns, so nothing here reads the machine's own policy.
  # The thresholds stay env-driven: a 45-minute one has to be reachable in
  # seconds, and every case below sets its own pair.
  export FACTORY_CONFIG="$TMP/config.json"
  printf '{"scope":{"orgs":["hausfold"]}}\n' >"$TMP/config.json"
  mkdir -p "$FACTORY_STATE_DIR"
  export FACTORY_WATCHDOG_INTERVAL=1
  export FACTORY_NO_WATCHDOG=1

  PATH="$TMP/bin:$PATH"
  export PATH
  export TRILL_CALLS="$TMP/trill-calls"
  cat >"$TMP/bin/trill" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRILL_CALLS"
EOF
  chmod +x "$TMP/bin/trill"
  FAKE_PID=""
  RACERS=""
}

teardown() {
  [ -z "$FAKE_PID" ] || kill "$FAKE_PID" 2>/dev/null || true
  # The race case starts pollers that are deliberately NOT the pidfile's — two
  # of the three are meant to lose it — so the pidfile alone cannot reap them.
  # A regression there means a poller that outlives its test and goes on
  # polling the runner underneath every case after it.
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

# A process that answers to the name the pidfile claims, without being a real
# poller. `is_watchdog` matches a command ENDING in `factory-watchdog run`, so
# the stub has to be a script of that name invoked with that verb — an
# `exec -a` rename cannot produce it, since the sleep duration would follow.
fake_poller() {
  cat >"$TMP/bin/factory-watchdog" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
  chmod +x "$TMP/bin/factory-watchdog"
  "$TMP/bin/factory-watchdog" run &
  FAKE_PID=$!
  printf '%s\n' "$FAKE_PID" >"$FACTORY_STATE_DIR/watchdog.pid"
}

# Wait up to 25s for a predicate, so nothing here races a 1s poll interval —
# nor the deliberately over-long `sleep`s the suspend cases install.
until_ok() {
  local i=0
  while [ $i -lt 250 ]; do
    if "$@"; then return 0; fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# How many of the NAMED pids are live pollers — never a `pgrep -f
# "factory-watchdog run"` over the process table, which is a different and
# wrong question. A poller forks a subshell for every command substitution in
# its loop, and a forked child inherits its parent's argv verbatim: `quiet=$(
# check "$slept")` alone runs a whole `factory-lease` and a `jq` while a second
# process with a byte-identical command line sits in the table. Any pattern
# match sampling that instant counts the one correct poller twice. That phantom
# is what made the race case below fail on a loaded runner while the claim it
# tests was doing exactly the right thing — and it fired more often the busier
# the machine, because the fork lives for as long as the poll takes.
#
# Asking `ps` about a pid we started answers the question the case actually
# has: of the processes THIS test spawned, how many are still pollers.
pollers_alive() {
  local pid n=0
  for pid in "$@"; do
    case "$(ps -p "$pid" -o command= 2>/dev/null)" in
    *factory-watchdog\ run) n=$((n + 1)) ;;
    esac
  done
  printf '%s\n' "$n"
}

# The predicate form, because `until_ok` re-runs its argv: a `$(pollers_alive
# ...)` written into until_ok's own arguments would be expanded once, before
# the first attempt, and every retry would re-test the first answer.
poller_count_is() {
  local want="$1"; shift
  [ "$(pollers_alive "$@")" -eq "$want" ]
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

# ── the heartbeat ─────────────────────────────────────────────────────────────

@test "live lease, recent pass, poller watching: healthy" {
  lease 3600 3600
  log_aged 300
  fake_poller
  run "$WD" once
  [ "$status" -eq 0 ]
  [[ "$output" == *"shift alive"* ]]
  [[ "$output" == *"5m ago"* ]]
}

@test "live lease and a recent pass but NO poller is its own fault, not healthy" {
  # `grant` spawns the poller with all output discarded, so a lost exec bit is
  # otherwise silent — and the SKILL tells the foreman to confirm at start.
  lease 3600 3600
  log_aged 300
  run "$WD" once
  [ "$status" -eq 4 ]
  [[ "$output" == *"NO POLLER"* ]]
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
  fake_poller
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "the NEWEST log is the heartbeat, not the first one found" {
  lease 21600 3600
  local old="$FACTORY_STATE_DIR/shift-20260828.log"
  echo "23:50 pass done: 0 merged" >"$old"
  touch -t "$(stamp "$(($(date +%s) - 86400))")" "$old"
  log_aged 120
  fake_poller
  run "$WD" once
  [ "$status" -eq 0 ]
}

# ── ⚠ regression: yesterday's log must not outrank today's grant ──────────────

@test "⚠ a fresh grant with only an old log is healthy, not instantly dead" {
  # Logs are per-day and never swept. Reading the newest log ALONE meant that
  # on every night after the first, `grant` spawned a poller that revoked the
  # lease before the foreman's first pass could write anything — so the shift
  # aborted at step 2 with "the grant did not take".
  local old="$FACTORY_STATE_DIR/shift-20260828.log"
  echo "23:50 pass done: 0 merged" >"$old"
  touch -t "$(stamp "$(($(date +%s) - 72000))")" "$old"
  lease 43200 30
  fake_poller
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "no log yet, lease just granted: healthy" {
  lease 43200 60
  fake_poller
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "no log yet, lease granted an hour ago: STALLED" {
  # A foreman that died before its first pass is exactly as dead as one that
  # died after ten, and leaves no log to say so.
  lease 43200 3600
  run "$WD" once
  [ "$status" -eq 3 ]
  [[ "$output" == *"STALLED"* ]]
}

# ── ⚠ regression: the watchdog's own lines are not a heartbeat ────────────────

@test "⚠ a persisting stall reaches DEAD and revokes, despite the watchdog logging" {
  # `note` appends to the same file whose mtime IS the heartbeat. Without the
  # mtime being restored, writing `foreman-stalled` reset quiet to zero, the
  # next poll read healthy and wrote `foreman-resumed`, and the pair alternated
  # forever — quiet could never exceed STALE, so this revoke was unreachable.
  FACTORY_STALE=2 FACTORY_DEAD=6 lease 21600 60
  log_aged 3
  FACTORY_STALE=2 FACTORY_DEAD=6 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test ! -f "$FACTORY_STATE_DIR/lease"
  kill $pid 2>/dev/null || true
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "foreman-gone" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  # The alternation the bug produced: one stall line, and never a resume, since
  # nothing ever landed a real pass.
  [ "$(grep -c "foreman-stalled" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log")" -eq 1 ]
  ! grep -q "foreman-resumed" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
}

# ── what `run` does about it ──────────────────────────────────────────────────

@test "a stall past DEAD revokes the lease and cards it" {
  lease 21600 10800
  log_aged 7200
  run "$WD" run
  [ "$status" -eq 3 ]
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "foreman-gone" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  grep -q "lease revoked" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  grep -q "fault" "$TRILL_CALLS"
}

@test "a stall short of DEAD says so but leaves the lease standing" {
  # The distinction the two thresholds exist for: a foreman whose network
  # dropped for one turn may still be mid-retry, and revoking under it turns a
  # recoverable blip into a shift that needs a person.
  lease 21600 3600
  log_aged 3600
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  # Waited on the CARD, not the log line: `note` runs first, so polling the log
  # would race the `notify` that follows it and kill the process between them.
  until_ok test -s "$TRILL_CALLS"
  kill $pid 2>/dev/null || true
  grep -q "foreman-stalled" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  [ -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "fault" "$TRILL_CALLS"
}

@test "the stall card fires once, not once per poll" {
  lease 21600 3600
  log_aged 3600
  "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test -s "$TRILL_CALLS"
  sleep 3
  kill $pid 2>/dev/null || true
  [ "$(wc -l <"$TRILL_CALLS")" -eq 1 ]
}

@test "run exits quietly when the lease ends under it" {
  # The ordinary end of a shift: the foreman was alive to the last pass and
  # wrote its own handover. The watchdog has nothing to add to it.
  lease 1 3600
  log_aged 60
  sleep 2
  run "$WD" run
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── ⚠ regression: a sleeping Mac is not a dead foreman ────────────────────────

# One "suspended machine" per line in $FACTORY_STATE_DIR/.naps, consumed in
# order, keyed on the poller's own interval so the suite's sub-second waits
# never eat one.
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

@test "⚠ a suspend is discounted, not counted against the foreman" {
  # Quiet time is measured in seconds this process was AWAKE for. A machine
  # asleep past DEAD wakes to a stale log through nobody's fault — the poller
  # was not running either — and a lease revoked out from under a living
  # foreman is the failure this script would be introducing rather than fixing.
  stub_sleep 8
  lease 21600 60
  log_aged 1
  FACTORY_STALE=4 FACTORY_DEAD=6 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok grep -q "machine-slept" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  sleep 2
  kill $pid 2>/dev/null || true
  # Wall clock is past DEAD; awake time is not, so nothing was revoked.
  [ -f "$FACTORY_STATE_DIR/lease" ]
  ! grep -q "foreman-gone" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
}

@test "⚠ repeated suspends still let a dead foreman reach DEAD" {
  # The bug the discount replaced: a grace WINDOW re-armed on every jump, so a
  # laptop that suspends and wakes all night — the documented default, with
  # `haus.power.lidAwake` off — renewed it faster than it expired. A genuinely
  # dead foreman then kept its lease until morning and never even drew a card.
  stub_sleep 5 5 5 5 5 5
  lease 21600 60
  log_aged 1
  FACTORY_STALE=2 FACTORY_DEAD=3 "$WD" run >/dev/null 2>&1 &
  local pid=$!
  until_ok test ! -f "$FACTORY_STATE_DIR/lease"
  kill $pid 2>/dev/null || true
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
  grep -q "machine-slept" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
  grep -q "foreman-gone" "$FACTORY_STATE_DIR/shift-$(date +%Y%m%d).log"
}

# ── the pidfile, and the wiring `factory-lease` depends on ────────────────────

@test "a second run is a no-op while one is already polling" {
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
  # — very much a live process, and very much not a watchdog.
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

@test "a stale pidfile does not read as a poller that is watching" {
  lease 21600 3600
  log_aged 60
  printf '%s\n' "$$" >"$FACTORY_STATE_DIR/watchdog.pid"
  run "$WD" once
  [ "$status" -eq 4 ]
  [[ "$output" == *"NO POLLER"* ]]
}

@test "ensure starts a poller when a live lease has lost one" {
  # `grant` establishes the invariant once; a poller can still be lost to a
  # reboot or an OOM kill, which is the likeliest overnight foreman-killer
  # after an API error precisely because it takes both at once.
  lease 21600 60
  log_aged 30
  run "$WD" once
  [ "$status" -eq 4 ]
  run "$WD" ensure
  [ "$status" -eq 0 ]
  [[ "$output" == *"poller watching"* ]]
  run "$WD" once
  [ "$status" -eq 0 ]
}

@test "ensure starts nothing when there is no lease to watch" {
  run "$WD" ensure
  [ "$status" -eq 1 ]
  [ ! -f "$FACTORY_STATE_DIR/watchdog.pid" ]
}

@test "⚠ a claim it could not write publishes nothing, not an empty pidfile" {
  # An empty pidfile is not inert. `poller_pid` reads it as nothing-alive, so
  # the next `run` deletes it and claims it — and if what it deleted was a live
  # poller's claim caught mid-write, that is a duplicate poller started on top
  # of one, which `revoke` cannot stop because it only ever stops the pid the
  # file names. So the claim writes the pid to a private name and hardlinks it
  # into place: `watchdog.pid` never exists while empty.
  #
  # The window itself is one preemption between a create and a write, which no
  # suite can schedule. A write that CANNOT land makes the same claim testable:
  # either the pid is published or nothing is. Under an O_EXCL create the file
  # is created before the write that fails, and the leftover is what the next
  # `run` would evict a live poller over.
  # The lease is EXPIRED on purpose. The claim runs before any lease is read,
  # so nothing here is weakened by it — but a regression that wrongly claims
  # then finds nothing to watch and exits, where a live lease would leave it
  # polling and HANG this case rather than fail it.
  lease -600 43200
  log_aged 7200
  run bash -c 'ulimit -f 0 2>/dev/null || exit 111; exec "$1" run' _ "$WD"
  [ "$status" -ne 111 ] || skip "this shell cannot set RLIMIT_FSIZE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not claim"* ]]
  [ ! -e "$FACTORY_STATE_DIR/watchdog.pid" ]
}

@test "⚠ two simultaneous grants leave exactly one poller" {
  # The pidfile is claimed by hardlinking a file that already holds the pid,
  # not by a read-then-write: the loser of a read-then-write became an orphan
  # `revoke` could not see, still holding a trap that would delete its
  # successor's pidfile.
  #
  # Counted over the three pids started here, and WAITED for rather than slept
  # at. The fixed second this used to take assumed the losers had already
  # exited, which a loaded runner need not honour; the count can only ever
  # FALL, since nothing here starts a fourth, so "reaches one" and "settles at
  # one" are the same statement. Two pollers that stay alive — the bug this
  # case exists for — still fail it, after `until_ok` has given them 25s.
  unset FACTORY_NO_WATCHDOG
  lease 21600 60
  log_aged 30
  local owner
  "$WD" run >/dev/null 2>&1 & RACERS="$!"
  "$WD" run >/dev/null 2>&1 & RACERS="$RACERS $!"
  "$WD" run >/dev/null 2>&1 & RACERS="$RACERS $!"
  until_ok test -s "$FACTORY_STATE_DIR/watchdog.pid"
  until_ok poller_count_is 1 $RACERS
  # And the survivor is the one the pidfile names, with the file still there: a
  # loser exiting on the old read-then-write held a trap that deleted its
  # successor's pidfile, which leaves exactly one poller and no claim on it.
  [ -s "$FACTORY_STATE_DIR/watchdog.pid" ]
  owner=$(cat "$FACTORY_STATE_DIR/watchdog.pid")
  poller_count_is 1 "$owner"
  case " $RACERS " in *" $owner "*) ;; *) false ;; esac
}

@test "grant starts a poller and revoke stops it" {
  # The invariant that makes this structural rather than a step the foreman
  # could forget: a live lease always has a watchdog.
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
# `FACTORY_STALE`, `FACTORY_DEAD` and `FACTORY_WATCHDOG_INTERVAL` exist so this
# suite can reach a 45-minute threshold in seconds. A poller inherits the
# environment of whoever ran `lease grant` — on a night shift, the foreman — so
# a variable that could LENGTHEN `dead` was a foreman able to keep its lease
# after it died, and `config print`'s watchdog row was not what was in force.

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

@test "a grant whose poller refused to start says so, rather than ✓ over nothing" {
  # `grant` discards `ensure`'s report, and used to discard its refusal with
  # it: an override the watchdog may not honour left a ✓ lease with no poller
  # and nothing on screen to say so until `watchdog once`.
  unset FACTORY_NO_WATCHDOG
  FACTORY_DEAD=999999 run "$LEASECMD" grant 30m
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: tier 1 until"* ]]
  [[ "$output" == *"watchdog did not start"* ]]
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

@test "an override equal to the policy's number is the policy's number" {
  # The boundary, so the check reads `-le` and not `-lt`: a suite that pins
  # the documented default through the env is not lengthening anything.
  lease 3600 0
  log_aged 1
  FACTORY_DEAD=5400 run "$WD" once
  [ "$status" -eq 4 ]   # a live lease, no poller — the override was accepted
}

# The same double-pin the scope and budget defaults carry, one suite over: the
# README quotes all three thresholds, so a retune that only edits the code
# would otherwise leave the manual saying 45 and 90 with nothing red.
@test "the three watchdog defaults are still the ones the README states" {
  lib="$BATS_TEST_DIRNAME/../lib/common.sh"
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -q '"stale": 2700' "$lib" && grep -qF '`watchdog.stale`, 2700' "$doc"
  grep -q '"dead": 5400' "$lib" && grep -qF '`watchdog.dead`, 5400' "$doc"
  grep -q '"interval": 300' "$lib" && grep -qF '`watchdog.interval` (300' "$doc"
}

@test "a fractional watchdog threshold is refused, not a death nobody notices" {
  # The budget dials' hole, one block over and worse. `[ "$quiet" -ge "5400.5" ]`
  # complains to stderr and returns non-zero, which the `if` reads as false — at
  # every poll, forever. So the foreman death this whole layer exists to notice
  # is never noticed and the lease stands until morning. `type == "number"` was
  # true of it and `> 1` was true of it; only wholeness is not.
  printf '{"scope":{"orgs":["hausfold"]},"watchdog":{"dead":5400.5}}\n' >"$TMP/config.json"
  run "$WD" once
  [ "$status" -ne 0 ]
  [[ "$output" == *"watchdog thresholds must be whole numbers of seconds"* ]]
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
