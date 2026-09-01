#!/usr/bin/env bats
#
# The presentation contract, from the workshop's docs/cli-presentation.md.
#
# Three things are checked here and they fail for different reasons: the BAN
# (factory never spells a colour itself), the DEGRADATION (a checkout with no
# snug still marks its report), and the STREAM + GATE (a report lands on fd 1,
# painted only when fd 1 is a terminal that wants it).

bats_require_minimum_version 1.5.0   # `run --separate-stderr`, which the two-streams cases need

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  FACTORY="$ROOT/bin/factory"
  # snug's bash half, off the store path of whatever `snug` is on PATH. Absent
  # in a bare checkout, which is what the `skip`s below are for — the ban and
  # the degradation still run there, and those are the half that can rot
  # silently.
  # Already pointed at one — CI checks snug out and exports this, and so does a
  # contributor testing a snug branch. It wins over whatever is on PATH,
  # because "the ui.sh I am changing" is the whole reason to set it.
  UI_SH="${FACTORY_UI_SH:-}"
  [ -n "$UI_SH" ] && [ -r "$UI_SH" ] || UI_SH=""
  if [ -z "$UI_SH" ] && command -v snug >/dev/null 2>&1; then
    local p
    p="$(cd "$(dirname "$(command -v snug)")/.." && pwd)/share/ui.sh"
    [ -r "$p" ] && UI_SH="$p"
  fi
}

# ── the ban ───────────────────────────────────────────────────────────────────

# haus's `haus.sh` strength, and for haus's reason: factory draws nothing but
# text and roles. It emits no OSC 8 hyperlink, no window title and no cursor
# control, so unlike a live-region painter it has no legal use for an escape at
# all — which makes the blanket ban cheaper to keep than a colour-only one that
# has to be argued about per line.
@test "no literal escape anywhere in the shipped shell" {
  run grep -rlP '\x1b|\\033|\\x1b|\\e\[' "$ROOT/bin" "$ROOT/libexec" "$ROOT/lib"
  [ "$status" -ne 0 ] || {
    echo "escapes in: $output" >&2
    false
  }
}

@test "no hand-picked 256-colour index" {
  run grep -rnE 'tput (setaf|setab)|\[38;5;|\[48;5;' "$ROOT/bin" "$ROOT/libexec" "$ROOT/lib"
  [ "$status" -ne 0 ] || {
    echo "hand-picked colour in: $output" >&2
    false
  }
}

# ── the degradation ───────────────────────────────────────────────────────────

@test "with no ui.sh the marks survive and nothing is painted" {
  run env -u FACTORY_UI_SH CLICOLOR_FORCE=1 "$FACTORY" lease status
  [ "$status" -eq 1 ]
  [[ "$output" == *"lease: none"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "with no ui.sh an error still goes to fd 2" {
  run env -u FACTORY_UI_SH "$FACTORY" nope
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown verb 'nope'"* ]]
}

# ── the stream, and the gate on it ────────────────────────────────────────────

@test "a report is marked on fd 1, and fd 1 alone" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run --separate-stderr env FACTORY_UI_SH="$UI_SH" "$FACTORY" lease status
  [[ "$output" == *"·"*"lease: none"* ]]
  [ -z "$stderr" ]
}

@test "an error is on fd 2, and fd 2 alone" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run --separate-stderr env FACTORY_UI_SH="$UI_SH" "$FACTORY" nope
  [ -z "$output" ]
  [[ "$stderr" == *"unknown verb 'nope'"* ]]
}

# A captured report is the case the two-streams rule exists for: bats runs
# every command with both streams on pipes, so a painted line here would be
# escapes written into a file.
@test "a piped report carries no escapes" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" "$FACTORY" config print
  [ "$status" -eq 0 ]
  [[ "$output" != *$'\033'* ]]
}

# The precedence, in the order snug states it: CLICOLOR_FORCE outranks
# NO_COLOR, and `dumb` outranks both — there is no escape a dumb terminal will
# not print at you literally. Asserted here rather than assumed, because factory
# does not implement any of it and a caller that quietly grew its own gate
# beside snug's is exactly how two answers to one question appear.
@test "CLICOLOR_FORCE paints a piped report" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" CLICOLOR_FORCE=1 "$FACTORY" lease status
  [[ "$output" == *$'\033'* ]]
}

@test "TERM=dumb stays plain even when colour is forced" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" CLICOLOR_FORCE=1 TERM=dumb "$FACTORY" lease status
  [[ "$output" == *"lease: none"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "NO_COLOR alone leaves the report plain" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" NO_COLOR=1 "$FACTORY" lease status
  [[ "$output" != *$'\033'* ]]
}

# ── the shape a caller captures ───────────────────────────────────────────────

@test "config path is a bare path, marked with nothing" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" CLICOLOR_FORCE=1 "$FACTORY" config path
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]
  [[ "$output" != *$'\033'* ]]
}
