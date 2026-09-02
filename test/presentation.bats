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
  # Isolated like every other suite here, and for a sharper reason: these cases
  # read `lease status`, and the machine running them is the one this tool grants
  # leases on. Without this, `bats test/` reds three cases on a developer's Mac
  # mid-shift — a live 12h lease, i.e. the tool doing exactly its job — and reds
  # nowhere else, so it reads as a regression that CI cannot reproduce.
  export FACTORY_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export FACTORY_CONFIG="$BATS_TEST_TMPDIR/config.json"
  mkdir -p "$FACTORY_STATE_DIR"
  export FACTORY_NO_WATCHDOG=1
  # snug's bash half, off the store path of whatever `snug` is on PATH. Absent
  # in a bare checkout, which is what the `skip`s below are for — the ban and
  # the degradation still run there, and those are the half that can rot
  # silently.
  # Already pointed at one — CI checks snug out and exports this, and so does a
  # contributor testing a snug branch. It wins over whatever is on PATH,
  # because "the ui.sh I am changing" is the whole reason to set it.
  UI_SH="${FACTORY_UI_SH:-}"
  [ -n "$UI_SH" ] && [ -r "$UI_SH" ] || UI_SH=""
  # Then the checkout CI makes at the rev flake.lock pins — the ui.sh this tool
  # actually ships against.
  [ -n "$UI_SH" ] || { [ -r "$ROOT/.snug/share/ui.sh" ] && UI_SH="$ROOT/.snug/share/ui.sh"; }
  # Last, whatever `snug` is on PATH. ⚠️ On a haus machine that is HAUS's pin,
  # not factory's, so a green run here is not proof against the rev in
  # flake.lock. CI is where that proof lives.
  if [ -z "$UI_SH" ] && command -v snug >/dev/null 2>&1; then
    local p
    p="$(cd "$(dirname "$(command -v snug)")/.." && pwd)/share/ui.sh"
    [ -r "$p" ] && UI_SH="$p"
  fi
  # The suite must never inherit the ambient one — several cases are about what
  # happens with NO painter, and `run env -u` only covers the child.
  unset FACTORY_UI_SH
}

# ── the ban ───────────────────────────────────────────────────────────────────

# haus's `haus.sh` strength, and for haus's reason: factory draws nothing but
# text and roles. It emits no OSC 8 hyperlink, no window title and no cursor
# control, so unlike a live-region painter it has no legal use for an escape at
# all — which makes the blanket ban cheaper to keep than a colour-only one that
# has to be argued about per line.
@test "no literal escape anywhere in the shipped shell" {
  # POSIX ERE, not `grep -P`. BSD grep has no -P and exits 2 on it — which is
  # non-zero, so the assertion below would PASS without having read a file. A
  # ban that goes green because the tool refused to run is the drift shape this
  # repo's own portability rule exists to stop.
  local esc; esc="$(printf '\033')"
  run grep -rlE "$esc"'|\\033|\\x1b|\\e\[' "$ROOT/bin" "$ROOT/libexec" "$ROOT/lib"
  [ "$status" -ne 0 ] || {
    echo "escapes in: $output" >&2
    false
  }
}

@test "the escape ban can actually see an escape" {
  # The ban above is a negative assertion, so nothing in it fails when the
  # search itself is broken. This is the positive half: plant one and find it.
  local esc; esc="$(printf '\033')"
  printf 'x=%s[31m\n' "$esc" >"$BATS_TEST_TMPDIR/planted.sh"
  run grep -rlE "$esc"'|\\033|\\x1b|\\e\[' "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *planted.sh* ]]
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
  run env -u FACTORY_UI_SH TERM=xterm-256color CLICOLOR_FORCE=1 "$FACTORY" lease status
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
  # TERM is named, not inherited. `CLICOLOR_FORCE` overrides the STREAM question
  # ("is fd 1 a terminal?"), never the CAPABILITY one ("can this terminal show a
  # colour?") — and a CI runner has no TERM at all, so snug resolves `none` and
  # forcing paints nothing. Correct of snug, and a case that inherits the
  # environment is asking two questions while pretending to ask one.
  run env FACTORY_UI_SH="$UI_SH" TERM=xterm-256color CLICOLOR_FORCE=1 "$FACTORY" lease status
  [[ "$output" == *$'\033'* ]]
}

@test "forcing colour on a terminal that has none paints nothing" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  # The other half of the case above, and the shape a CI runner is actually in.
  run env -u TERM FACTORY_UI_SH="$UI_SH" CLICOLOR_FORCE=1 "$FACTORY" lease status
  [[ "$output" == *"lease: none"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "TERM=dumb stays plain even when colour is forced" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" TERM=dumb CLICOLOR_FORCE=1 "$FACTORY" lease status
  [[ "$output" == *"lease: none"* ]]
  [[ "$output" != *$'\033'* ]]
}

@test "NO_COLOR alone leaves the report plain" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" TERM=xterm-256color NO_COLOR=1 "$FACTORY" lease status
  [[ "$output" != *$'\033'* ]]
}

# ── the shape a caller captures ───────────────────────────────────────────────

@test "config path is a bare path, marked with nothing" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" TERM=xterm-256color CLICOLOR_FORCE=1 "$FACTORY" config path
  [ "$status" -eq 0 ]
  [[ "$output" == /* ]]
  [[ "$output" != *$'\033'* ]]
}
