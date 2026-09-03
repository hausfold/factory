#!/usr/bin/env bats
# The surface `bin/factory` presents to an AGENT: which flags each verb of the
# dispatcher answers, and what it does with one it does not know.
#
# `doctor` is most of the file because it is the verb with two readers. It
# renders one set of checks twice — a checklist for a person, a document for a
# caller — so every case here asks whether the second rendering says the same
# thing as the first: the same checks, the same verdict, the same exit code. A
# `--json` that quietly dropped a check, or answered 0 where the human report
# drew a ✗, would be the silent failure this repo's first rule is about, and it
# is silent precisely because the human report next to it still looks right.
#
# The other half is the refusal. A verb that ignores a flag it does not
# implement leaves a caller unable to tell "this verb has no JSON" from "the
# JSON is malformed" — so every unknown flag lands on fd 2 with nothing on fd 1,
# which is what the cases here pin for `doctor` and for `config`.
#
# ⚠ Three cases are regressions. `doctor --json` used to be swallowed whole:
# the flag parsed nowhere, so it printed prose and exited 0. `config print`
# compared $2 against `--json` and fell through to the human table for anything
# else, the same swallow one verb over. And `lib/ui.sh` is sourced twice in this
# process — once by `bin/factory`, again by the `common.sh` that `cmd_doctor`
# pulls in — which used to make the fallback painter look like snug on the
# second pass and turned every refusal here into a `ui_fail: command not found`.
#
# `gh` is stubbed and PATH is PREPENDED: the real one is authenticated on a
# developer's Mac and `doctor` asks it who you are, so an unstubbed suite makes
# a network call per case and reds on a plane. HOME is moved into the tmpdir for
# the same reason — the legacy-state note reads a path under it, and a machine
# that once ran the workshop's ancestor would otherwise have one more check than
# CI does.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`, which the two-streams case needs

setup() {
  TMP="$BATS_TEST_TMPDIR"
  ROOT="$TMP/root"
  mkdir -p "$ROOT/bin" "$ROOT/lib" "$ROOT/libexec" "$TMP/bin" "$TMP/home"
  cp "$BATS_TEST_DIRNAME/../bin/factory" "$ROOT/bin/"
  # The whole lib/ and the whole libexec/: `common.sh` sources `ui.sh` beside
  # it, and `doctor` execs both sub-verbs. A copy list that names some of each
  # is a harness that reds on a file the tool ships correctly.
  cp "$BATS_TEST_DIRNAME"/../lib/*.sh "$ROOT/lib/"
  cp "$BATS_TEST_DIRNAME"/../libexec/* "$ROOT/libexec/"
  cp "$BATS_TEST_DIRNAME/../VERSION" "$ROOT/"
  FACTORY="$ROOT/bin/factory"

  export HOME="$TMP/home"
  export FACTORY_STATE_DIR="$TMP/state"
  export FACTORY_CONFIG="$TMP/config.json"
  # An org in scope, so the one check that would otherwise block is green and
  # each case below decides for itself what goes red.
  printf '{"scope":{"orgs":["hausfold"]}}\n' >"$FACTORY_CONFIG"
  mkdir -p "$FACTORY_STATE_DIR"
  export FACTORY_NO_WATCHDOG=1

  PATH="$TMP/bin:$PATH"
  export PATH
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
"auth status") exit 0 ;;
"api user -q .login") echo tester ;;
esac
EOF
  chmod +x "$TMP/bin/gh"
  # A trill on PATH, so the notify check resolves the same here as on a runner.
  # It is never RUN by `doctor`, which only asks whether it exists — but the
  # answer to that question is the difference between an ok and a note, and a
  # note is the difference between doctor exiting 0 and 1 — never 2, which
  # wants a BLOCKING check and this arm never is. A suite whose verdict depends
  # on what the developer happens to have installed is a suite that reds on a
  # plane.
  printf '#!/usr/bin/env bash\n' >"$TMP/bin/trill"
  chmod +x "$TMP/bin/trill"

  # snug's bash half, probed the way test/presentation.bats probes it. Only the
  # escape case needs it; everything else here is about the document, which no
  # painter ever touches.
  UI_SH="${FACTORY_UI_SH:-}"
  [ -n "$UI_SH" ] && [ -r "$UI_SH" ] || UI_SH=""
  [ -n "$UI_SH" ] || { [ -r "$BATS_TEST_DIRNAME/../.snug/share/ui.sh" ] && UI_SH="$BATS_TEST_DIRNAME/../.snug/share/ui.sh"; }
  if [ -z "$UI_SH" ] && command -v snug >/dev/null 2>&1; then
    local p
    p="$(cd "$(dirname "$(command -v snug)")/.." && pwd)/share/ui.sh"
    [ -r "$p" ] && UI_SH="$p"
  fi
  unset FACTORY_UI_SH
}

# ── the flag ──────────────────────────────────────────────────────────────────

# ⚠ REGRESSION. `cmd_doctor` never looked at "$@", so this printed the human
# checklist and exited 0 — a verb that accepts a flag it does not implement.
@test "doctor --json emits JSON, not the human checklist" {
  run --separate-stderr "$FACTORY" doctor --json
  [ -z "$stderr" ]
  echo "$output" | jq -e . >/dev/null
  [[ "$output" != *"✓"* ]]
}

# The other half of the same rule, and the shape haus's own agent-surface suite
# asserts: an unknown flag is REFUSED, on fd 2, with nothing on fd 1. A caller
# that gets prose back cannot tell a verb without JSON from JSON it failed to
# parse; a caller that gets exit 2 and an empty stdout can.
@test "doctor refuses an unknown flag on fd 2, with nothing on fd 1" {
  run --separate-stderr "$FACTORY" doctor --bogus
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"doctor takes --json"* ]]
}

# ⚠ REGRESSION. ui.sh is sourced twice in one process and the second pass used
# to find the FALLBACK's `ui_paint_role`, conclude snug was present on a machine
# with none, and send the refusal above into `ui_fail: command not found` —
# exit 127 and a bash error where a named refusal belonged.
@test "the refusal survives a checkout with no snug" {
  run --separate-stderr env -u FACTORY_UI_SH "$FACTORY" doctor --bogus
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"factory: doctor takes --json"* ]]
  [[ "$stderr" != *"command not found"* ]]
}

# ── the two readers agree ─────────────────────────────────────────────────────

@test "doctor --json carries every check the human report draws" {
  run "$FACTORY" doctor
  local human_status="$status"
  # Every check is one marked line; the only other marked line is the verdict.
  local drawn
  drawn=$(printf '%s\n' "$output" | grep -c '^[✓⚠✗]')
  run "$FACTORY" doctor --json
  [ "$status" -eq "$human_status" ]
  [ "$(jq '.checks | length' <<<"$output")" -eq "$((drawn - 1))" ]
}

@test "doctor --json and the human report agree on the verdict line" {
  run "$FACTORY" doctor --json
  local line
  line=$(jq -r .line <<<"$output")
  run "$FACTORY" doctor
  [[ "$output" == *"$line"* ]]
}

# The Development block tells a reader how big this suite is, and that number
# has now gone stale twice — once at 120 against 133, once in the CI comment
# beside it. It is a claim about a thing this file can count, so it counts it.
@test "the case count the README states is the case count there is" {
  local n
  n=$(grep -h '^@test' "$BATS_TEST_DIRNAME"/*.bats | wc -l | tr -d ' ')
  grep -qF "bats test/                                    # $n cases" \
    "$BATS_TEST_DIRNAME/../README.md"
}

# ── whether anything will reach you ───────────────────────────────────────────
# `doctor` asks whether this machine can run a shift, and until these cases it
# never asked the half that matters at 3am: a shift that merges correctly and
# cards nowhere reports its red CI to nobody. Three arms, three severities.

@test "doctor names a notify.command that PATH cannot find, and blocks on it" {
  printf '{"scope":{"orgs":["hausfold"]},"notify":{"mode":"command","command":["no-such-notifier"]}}\n' \
    >"$FACTORY_CONFIG"
  run "$FACTORY" doctor
  [ "$status" -eq 2 ]
  [[ "$output" == *"no-such-notifier, which is not on PATH"* ]]
}

@test "a notify.command that exists is green, and names what it will run" {
  printf '#!/usr/bin/env bash\n' >"$TMP/bin/my-notifier"
  chmod +x "$TMP/bin/my-notifier"
  printf '{"scope":{"orgs":["hausfold"]},"notify":{"mode":"command","command":["my-notifier","--to","me"]}}\n' \
    >"$FACTORY_CONFIG"
  run "$FACTORY" doctor
  [[ "$output" == *"runs my-notifier"* ]]
  [[ "$output" != *"not on PATH"* ]]
}

@test "notify.mode off is a note, not a block — it is a decision, not a fault" {
  printf '{"scope":{"orgs":["hausfold"]},"notify":{"mode":"off"}}\n' >"$FACTORY_CONFIG"
  run "$FACTORY" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"card nowhere"* ]]
}

@test "auto with no trill is a note too, because that is a stranger's machine" {
  # PATH is PREPENDED, so deleting the stub falls through to whatever trill the
  # developer has installed. This case is about a machine with none, which is
  # the runner and not their Mac — skipped there rather than faked, the same
  # way presentation.bats skips what needs snug.
  rm -f "$TMP/bin/trill"
  command -v trill >/dev/null 2>&1 && skip "a real trill is on PATH; this case is about a machine without one"
  run "$FACTORY" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *"trill is not installed"* ]]
}

@test "a quiet machine is ready, and says so in both exit code and field" {
  run "$FACTORY" doctor --json
  # No org missing, gh answering, state dir writable: nothing blocks, and the
  # two notes are the budget feed and the empty afterMerge list. Counted rather
  # than described: without the trill stub `setup` installs there would be a
  # third, and a comment is not what keeps that stub load-bearing.
  [ "$status" -eq 1 ]
  [ "$(jq -r .notes <<<"$output")" = 2 ]
  [ "$(jq -r .ready <<<"$output")" = true ]
  [ "$(jq -r .blocking <<<"$output")" = 0 ]
  [ "$(jq -r .exit <<<"$output")" = 1 ]
}

@test "every check names its section and its own id" {
  run "$FACTORY" doctor --json
  [ "$status" -eq 1 ]
  # The ids are the contract: an agent branches on them, so a rename is a
  # breaking change and belongs here rather than in a caller's surprise.
  local ids
  ids=$(jq -r '[.checks[].check] | join(" ")' <<<"$output")
  [[ "$ids" == "jq gh config-file scope digest budget after-merge notify state-dir" ]]
  [ "$(jq -r '[.checks[] | select(.section == "")] | length' <<<"$output")" = 0 ]
  [ "$(jq -r '[.checks[] | select(.state | test("^(ok|warn|bad)$") | not)] | length' <<<"$output")" = 0 ]
}

# ── what goes wrong ───────────────────────────────────────────────────────────

@test "a blocking check blocks in JSON too" {
  # A state dir that cannot be made: a file already sits where it must go.
  export FACTORY_STATE_DIR="$TMP/not-a-dir"
  : >"$FACTORY_STATE_DIR"
  run "$FACTORY" doctor --json
  [ "$status" -eq 2 ]
  [ "$(jq -r .ready <<<"$output")" = false ]
  [ "$(jq -r '.checks[] | select(.check == "state-dir") | .state' <<<"$output")" = bad ]
}

@test "doctor --json nests the sub-verbs whole rather than scraping their lines" {
  # --separate-stderr, like the two refusal cases above: bare `run` folds fd 2
  # into $output, so one stray narration line would fail the jq below as a
  # parse error at some column rather than as the two-streams break it is.
  run --separate-stderr "$FACTORY" doctor --json
  # `lease status --json` and `watchdog once --json` own these shapes; doctor
  # asks for them in JSON and embeds them. One verb never parses another's
  # human line.
  [ "$(jq -r .lease.live <<<"$output")" = false ]
  [ "$(jq -r .lease.line <<<"$output")" = "lease: none" ]
  [ "$(jq -r .watchdog.state <<<"$output")" = no-lease ]
  [ "$(jq -e 'has("pollerPid")' <<<"$(jq -c .watchdog <<<"$output")")" = true ]
}

# Silence is a claim: a doctor that could not read the lease must not emit the
# document a machine with no lease emits.
@test "a sub-verb that cannot be run is named, not omitted" {
  chmod -x "$ROOT/libexec/factory-lease"
  run "$FACTORY" doctor --json
  [ "$(jq -r .lease.error <<<"$output")" = lease-unknown ]
  # And the rest of the report still stands — the doctor's own checks did run.
  [ "$(jq '.checks | length' <<<"$output")" -gt 0 ]
}

# ── the same refusal, one verb over ───────────────────────────────

# ⚠ REGRESSION. `config print` tested $2 for `--json` and drew the human table
# for everything else, so `factory config print --josn` reported a policy under
# a flag that did nothing.
@test "config print refuses an unknown flag on fd 2, with nothing on fd 1" {
  run --separate-stderr "$FACTORY" config print --josn
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"config print takes --json"* ]]
}

@test "config print still answers --json, and bare" {
  run "$FACTORY" config print --json
  [ "$status" -eq 0 ]
  [ "$(jq -r '.scope.orgs[0]' <<<"$output")" = hausfold ]
  run "$FACTORY" config print
  [ "$status" -eq 0 ]
  [[ "$output" == *"hausfold"* ]]
}

# `path` is what a caller captures with `cd "$(dirname "$(factory config
# path)")"`, so a flag it silently ate would be a path printed under a promise
# it never kept.
@test "config path and init take no flags at all" {
  run --separate-stderr "$FACTORY" config path --json
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"config path takes no flags"* ]]
  run --separate-stderr "$FACTORY" config init --force
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"config init takes no flags"* ]]
}

@test "config path is still a bare path on fd 1" {
  run --separate-stderr "$FACTORY" config path
  [ "$status" -eq 0 ]
  [ "$output" = "$FACTORY_CONFIG" ]
  [ -z "$stderr" ]
}

# ── the stream ────────────────────────────────────────────────────────────────

# The JSON path must BYPASS the painter, not strip escapes back out of it. With
# colour forced and snug loaded, a single escape here means a caller's `jq`
# gets a document it cannot parse.
@test "doctor --json is escape-free even when colour is forced" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  run env FACTORY_UI_SH="$UI_SH" TERM=xterm-256color CLICOLOR_FORCE=1 "$FACTORY" doctor --json
  [[ "$output" != *$'\033'* ]]
  echo "$output" | jq -e . >/dev/null
}

@test "the human report is still painted when colour is forced" {
  [ -n "$UI_SH" ] || skip "no snug on PATH"
  # The other half: bypassing the painter for `--json` must not have bypassed
  # it for the reader `doctor` was written for.
  run env FACTORY_UI_SH="$UI_SH" TERM=xterm-256color CLICOLOR_FORCE=1 "$FACTORY" doctor
  [[ "$output" == *$'\033'* ]]
}
