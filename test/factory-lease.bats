#!/usr/bin/env bats
# Unit tests for `libexec/factory-lease` — the standing merge grant, and until
# now the one of the four verbs with no suite of its own.
#
# It was reached only sideways: factory-watchdog.bats grants a lease to test
# the poller that `grant` starts, factory-shift.bats writes the lease file
# directly rather than through `grant`, and agent-surface.bats `chmod -x`es
# the script to make `doctor` report `lease-unknown`. Every one of those has a
# subject that is somewhere else, so nothing had ever handed `grant` a
# duration nobody would type — which is where all four of the parse cases
# below were sitting.
#
# The invariant that a live lease always has a watchdog belongs to
# factory-watchdog.bats and stays there: `grant`'s poller inherits bats'
# immediate-output pipe on fd 3, so a case here that spawned a second one
# would block the whole run for a poll interval after killing it.
# `FACTORY_NO_WATCHDOG=1` is set for every case in this file.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`, for the flag refusal

setup() {
  TMP="$BATS_TEST_TMPDIR"
  mkdir -p "$TMP/root/libexec" "$TMP/root/lib"
  cp "$BATS_TEST_DIRNAME/../libexec/factory-lease" "$TMP/root/libexec/"
  # The whole lib/, not a named file: common.sh sources ui.sh beside it, and a
  # copy list naming one of two is a harness that reds on a file the tool
  # ships correctly.
  cp "$BATS_TEST_DIRNAME"/../lib/*.sh "$TMP/root/lib/"
  cp "$BATS_TEST_DIRNAME/../VERSION" "$TMP/root/"
  LEASECMD="$TMP/root/libexec/factory-lease"

  export FACTORY_STATE_DIR="$TMP/state"
  export FACTORY_CONFIG="$TMP/config.json"
  printf '{}\n' >"$TMP/config.json"
  mkdir -p "$FACTORY_STATE_DIR"
  # No watchdog is copied into $TMP either, so `grant`'s `[ -x "$WATCHDOG" ]`
  # is already false — this is the belt to that braces, and says so out loud.
  export FACTORY_NO_WATCHDOG=1
}

# bats-core ships no `fail`, and this suite loads no assertion library — three
# lines here rather than a dependency. It exists for the two cases that loop:
# a bare `[ … ]` fails the case correctly but cannot say WHICH input did it.
fail() {
  echo "$1" >&2
  return 1
}

# A lease expiring $1 seconds from now (negative for already-expired).
lease_expiring() {
  printf '%s\t1\t%s\n' "$(($(date +%s) + $1))" "$(date +%s)" >"$FACTORY_STATE_DIR/lease"
}

# The lease's expiry, as seconds from the moment this is called.
expires_in() {
  local expires
  read -r expires _ <"$FACTORY_STATE_DIR/lease"
  echo "$((expires - $(date +%s)))"
}

@test "usage on no argument" {
  run "$LEASECMD"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "usage on an unrecognised subcommand" {
  run "$LEASECMD" bogus
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "grant with no duration argument is a usage error" {
  run "$LEASECMD" grant
  [ "$status" -eq 2 ]
}

@test "an unknown flag is refused on fd 2, not ignored" {
  # `status --jsno` answered in prose and exit 0 — which a caller cannot tell
  # from a verb that has no JSON, the swallow every other verb here refuses.
  lease_expiring 3600
  run --separate-stderr "$LEASECMD" status --jsno
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown flag '--jsno'"* ]]
}

@test "status and revoke take no further argument" {
  lease_expiring 3600
  run "$LEASECMD" status now
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  run "$LEASECMD" revoke all
  [ "$status" -eq 2 ]
  # Refused means not done: the lease is still there.
  [ -s "$FACTORY_STATE_DIR/lease" ]
}

# ── parse_duration ───────────────────────────────────────────────────────────
# Four shapes, each of which reached the arithmetic before this suite. Every
# assertion is its own statement on its own line: `[ A ] && [ B ]` anywhere but
# the last line of a case is a test bats does NOT fail when A fails.

@test "⚠ a bare unit with no digits is a usage error, not a bash arithmetic crash" {
  for dur in h m d; do
    run "$LEASECMD" grant "$dur"
    [ "$status" -eq 2 ] || fail "grant $dur exited $status, not 2: $output"
    [[ "$output" == *"bad duration"* ]] || fail "grant $dur: $output"
    [[ "$output" != *"arithmetic"* ]] || fail "grant $dur leaked bash's error: $output"
  done
}

@test "⚠ a bare 's' with no digits is a usage error, not a lease that expires the instant it is read" {
  run "$LEASECMD" grant s
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad duration"* ]]
  # "" is a valid arithmetic operand (0), so this one never crashed — it
  # granted, printed ✓, and was expired by the time `status` read it.
  [ ! -s "$FACTORY_STATE_DIR/lease" ]
}

@test "⚠ a leading zero is decimal, not octal — 08h is not a crash and 010m is not eight minutes" {
  # `num` passes a zero-padded number and bash reads one as base 8.
  run "$LEASECMD" grant 08h
  [ "$status" -eq 0 ] || fail "grant 08h exited $status: $output"
  [[ "$output" != *"base"* ]] || fail "grant 08h leaked bash's octal error: $output"
  local left
  left=$(expires_in)
  [ "$left" -ge 28795 ] || fail "08h granted ${left}s, not 8 hours"
  [ "$left" -le 28800 ] || fail "08h granted ${left}s, not 8 hours"

  run "$LEASECMD" grant 010m
  [ "$status" -eq 0 ] || fail "grant 010m exited $status: $output"
  left=$(expires_in)
  [ "$left" -ge 595 ] || fail "010m granted ${left}s — read as octal, that is 8 minutes"
  [ "$left" -le 600 ] || fail "010m granted ${left}s, not 10 minutes"
}

@test "⚠ a zero duration is refused — a lease granted for no time is one already expired" {
  for dur in 0m 0s 00d; do
    run "$LEASECMD" grant "$dur"
    [ "$status" -eq 2 ] || fail "grant $dur exited $status, not 2: $output"
    [[ "$output" == *"zero"* ]] || fail "grant $dur: $output"
    [ ! -s "$FACTORY_STATE_DIR/lease" ] || fail "grant $dur wrote a lease"
  done
}

# A duration can leave the range at three different frames, and the outcome
# without a guard is the same at all three: a lease written with a wrapped
# expiry, `grant` printing ✓ on a line ending in a bare "until" because `at`
# cannot format the stamp, and the very next `status` calling the state file
# this verb has just written unreadable.
#
# Each case names the MESSAGE, not just the refusal, because the guards back
# each other up: remove any one and another still refuses, so an assertion on
# the exit code alone re-blesses two of the three. The message is the part that
# stops being true.
@test "⚠ a number too long for the arithmetic says so, and does not call itself zero" {
  # 19 digits: `10#` wraps it negative, and the zero check downstream then
  # refuses it with a sentence that is not true of what was typed.
  run "$LEASECMD" grant 9223372036854775808s
  [ "$status" -eq 2 ]
  [[ "$output" == *"more seconds than this machine can count"* ]] || fail "$output"
  [[ "$output" != *"is zero"* ]] || fail "refused a 19-digit number as zero: $output"
  [ ! -s "$FACTORY_STATE_DIR/lease" ]
}

@test "⚠ a number that survives the parse but not the multiply is refused on the multiply" {
  # 15 digits, so `10#` is exact; × 86400 is what leaves the range.
  run "$LEASECMD" grant 999999999999999d
  [ "$status" -eq 2 ]
  [[ "$output" == *"more seconds than this machine can count"* ]] || fail "$output"
  [ ! -s "$FACTORY_STATE_DIR/lease" ]
}

@test "⚠ a duration that multiplies cleanly and still has no representable expiry is refused" {
  # Clears parse_duration outright — the wrap is `now + secs`, which only the
  # grant arm can see. 106751991167300 × 86400 is under 2^63; plus the clock
  # it is not.
  for dur in 106751991167300d 2562047788015215h; do
    run "$LEASECMD" grant "$dur"
    [ "$status" -eq 2 ] || fail "grant $dur exited $status, not 2: $output"
    [[ "$output" == *"expiry"* ]] || fail "grant $dur: $output"
    [ ! -s "$FACTORY_STATE_DIR/lease" ] || fail "grant $dur wrote a lease"
  done
}

@test "the bound is the machine's, not a policy — ten years still grants a stamped line" {
  run "$LEASECMD" grant 3650d
  [ "$status" -eq 0 ] || fail "grant 3650d exited $status: $output"
  # Not a bare "until": the regression wrote the lease and left the stamp off.
  [[ "$output" =~ until[[:space:]]+[A-Za-z] ]] || fail "no stamp after until: $output"
  run "$LEASECMD" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: tier 1 ·"* ]]
}

@test "digits with no unit is a usage error" {
  run "$LEASECMD" grant 30
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad duration"* ]]
}

@test "a negative duration is a usage error" {
  run "$LEASECMD" grant -5m
  [ "$status" -eq 2 ]
}

@test "a fractional duration is a usage error" {
  run "$LEASECMD" grant 5.5h
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad duration"* ]]
}

@test "a duration mixing two units is a usage error, not the number half of it" {
  run "$LEASECMD" grant 1h2m
  [ "$status" -eq 2 ]
  [[ "$output" == *"bad duration"* ]]
}

# One bound per line, and the clock re-read per grant: an assertion that is not
# the case's last statement has to fail the case on its own.
@test "each unit multiplies by the right number of seconds" {
  "$LEASECMD" grant 30m >/dev/null
  local left
  left=$(expires_in)
  [ "$left" -ge 1795 ] || fail "30m granted ${left}s"
  [ "$left" -le 1800 ] || fail "30m granted ${left}s"

  "$LEASECMD" grant 12h >/dev/null
  left=$(expires_in)
  [ "$left" -ge 43195 ] || fail "12h granted ${left}s"
  [ "$left" -le 43200 ] || fail "12h granted ${left}s"

  "$LEASECMD" grant 2d >/dev/null
  left=$(expires_in)
  [ "$left" -ge 172795 ] || fail "2d granted ${left}s"
  [ "$left" -le 172800 ] || fail "2d granted ${left}s"

  "$LEASECMD" grant 90s >/dev/null
  left=$(expires_in)
  [ "$left" -ge 85 ] || fail "90s granted ${left}s"
  [ "$left" -le 90 ] || fail "90s granted ${left}s"
}

# ── tier ──────────────────────────────────────────────────────────────────────

@test "a grant naming a tier other than 1 is refused" {
  run "$LEASECMD" grant 12h 2
  [ "$status" -eq 2 ]
  [[ "$output" == *"only tier 1 exists"* ]]
  [ ! -s "$FACTORY_STATE_DIR/lease" ]
}

# ── status ────────────────────────────────────────────────────────────────────

@test "status with no lease file: none, exit 1" {
  run "$LEASECMD" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"lease: none"* ]]
}

@test "status with an expired lease: exit 1, names when it expired" {
  lease_expiring -60
  run "$LEASECMD" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"lease: expired"* ]]
}

@test "status with an unreadable lease file: exit 1, does not crash" {
  printf 'garbage\n' >"$FACTORY_STATE_DIR/lease"
  run "$LEASECMD" status
  [ "$status" -eq 1 ]
  [[ "$output" == *"lease: unreadable"* ]]
}

@test "status with a live lease: exit 0, --json carries secondsLeft" {
  lease_expiring 3600
  run "$LEASECMD" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: tier 1"* ]]

  run "$LEASECMD" status --json
  [ "$status" -eq 0 ]
  local live seconds_left
  live=$(jq -r .live <<<"$output")
  seconds_left=$(jq -r .secondsLeft <<<"$output")
  [ "$live" = true ] || fail "live was $live"
  [ "$seconds_left" -ge 3595 ] || fail "secondsLeft was $seconds_left"
  [ "$seconds_left" -le 3600 ] || fail "secondsLeft was $seconds_left"
}

@test "status --json on no lease reports live:false rather than omitting the shape" {
  run "$LEASECMD" status --json
  [ "$status" -eq 1 ]
  [ "$(jq -r .live <<<"$output")" = false ]
  [ "$(jq -r .secondsLeft <<<"$output")" = 0 ]
}

# ── revoke ────────────────────────────────────────────────────────────────────

@test "revoke on a live lease removes it" {
  lease_expiring 3600
  run "$LEASECMD" revoke
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: revoked"* ]]
  [ ! -f "$FACTORY_STATE_DIR/lease" ]
}

@test "revoke with no lease present still succeeds" {
  run "$LEASECMD" revoke
  [ "$status" -eq 0 ]
  [[ "$output" == *"lease: revoked"* ]]
}
