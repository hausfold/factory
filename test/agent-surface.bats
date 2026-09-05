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
  # `skill` reads `ai/` off FACTORY_HOME, and it reads the DIRECTORY rather
  # than a list — a $ROOT without it turns every case below into "no such
  # skill" against a tool that ships two.
  #
  # Read-only, because that is the SHIPPED shape: `flake.nix` copies `ai/` into
  # the store and store files are 444, so `cp` inheriting the source's mode is
  # what a Nix-installed factory actually does. A fixture taken from a writable
  # checkout is 644 and would leave the "install twice" case green forever. The
  # files only — the directories stay writable so bats can clean its tmpdir.
  cp -R "$BATS_TEST_DIRNAME/../ai" "$ROOT/ai"
  chmod a-w "$ROOT"/ai/SKILL.md "$ROOT"/ai/*/SKILL.md
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

# ⚠ REGRESSION. `doctor` read `.afterMerge.commands | length` off a string and
# reported its character count as a command count, ✓ — while the pass those
# commands were for iterated the same string with `.[]?` and ran nothing. The
# one verb whose job is to say whether a night can run approved the config
# that would make it run silent.
@test "doctor refuses a config whose lists are strings, rather than counting their letters" {
  printf '{"scope":{"orgs":["hausfold"]},"afterMerge":{"commands":"make lockfiles"}}\n' >"$FACTORY_CONFIG"
  run --separate-stderr "$FACTORY" doctor
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"afterMerge.commands must be an array of non-empty strings"* ]]
  [[ "$output" != *"14 command"* ]]
  # And the same document under --json: a blocking config is exit 2 either way,
  # never a `ready: true` with a check that happened to parse.
  run --separate-stderr "$FACTORY" doctor --json
  [ "$status" -eq 2 ]
  [[ "$output" != *'"ready":true'* ]]
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

# ── the verb a stranger runs ──────────────────────────────────────────────────
#
# `skill install` is the whole standalone install: a haus machine gets these
# files from `haus.ai.skill` and never calls this, so nothing else on the
# machine exercises it and nothing here did either — it was the one verb of the
# dispatcher with no case at all. Four of the cases below are regressions found
# by running it rather than reading it.
#
# It is also the verb that WRITES into $HOME, which is why every case names its
# destination: a bug here is not a wrong exit code, it is a file in a directory
# the caller did not ask for.

@test "skill prints the tool's own document, and a named sibling" {
  run "$FACTORY" skill
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: factory"* ]]
  run "$FACTORY" skill nightshift
  [ "$status" -eq 0 ]
  [[ "$output" == *"name: nightshift"* ]]
}

@test "a skill this tool does not ship is a refusal on fd 2, not an empty document" {
  run --separate-stderr "$FACTORY" skill nosuch
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"no such skill 'nosuch'"* ]]
}

# ⚠ REGRESSION. `--dir` with nothing after it reached `shift 2` with one
# positional left, which returns 1 — and under `set -e` ended the verb there,
# with nothing on either stream and the exit code this tool documents as
# "nothing to do". A typo read as a no-op.
@test "a flag with no value is a usage refusal, not a silent exit" {
  run --separate-stderr "$FACTORY" skill install --dir
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"--dir needs a path"* ]]
  run --separate-stderr "$FACTORY" skill install --client
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--client needs one of"* ]]
}

# ⚠ REGRESSION, and the one that wrote files. An empty value is an unset shell
# variable — `factory skill install --dir "$scratch"` with `scratch` unset —
# and it used to fall through to discovery, installing into every agent client
# on the machine while the caller believed it had named one throwaway path.
@test "an empty flag value writes nowhere, rather than everywhere" {
  mkdir -p "$HOME/.claude" "$HOME/.codex"
  run --separate-stderr "$FACTORY" skill install --dir ""
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--dir needs a path"* ]]
  run --separate-stderr "$FACTORY" skill install --client ""
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"--client needs one of"* ]]
  [ -z "$(find "$HOME" -name SKILL.md)" ]
}

# Two answers to "where", where only one can be honoured.
@test "--dir and --client together are refused rather than silently ranked" {
  run --separate-stderr "$FACTORY" skill install --dir "$TMP/scratch" --client claude
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"both name a destination"* ]]
  [ ! -d "$TMP/scratch" ]
}

@test "an unknown client and an unknown flag both name what was expected" {
  run --separate-stderr "$FACTORY" skill install --client emacs
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown client 'emacs'"* ]]
  [[ "$stderr" == *"claude, codex, opencode, pi"* ]]
  run --separate-stderr "$FACTORY" skill install --into "$TMP/x"
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"unknown flag '--into'"* ]]
}

# `install` means ALL of them: a tool that ships a second skill and installs
# only its first reaches no standalone user with it.
@test "install writes every skill this tool ships, one directory each" {
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 0 ]
  [ -f "$TMP/scratch/factory/SKILL.md" ]
  [ -f "$TMP/scratch/nightshift/SKILL.md" ]
  [[ "$output" == *"2 written, 0 left alone"* ]]
}

@test "a machine with no agent client is told which flag would have answered" {
  run --separate-stderr "$FACTORY" skill install
  [ "$status" -eq 2 ]
  [[ "$stderr" == *"no agent client found"* ]]
}

# Discovery is by the client's PARENT existing — `~/.claude` is what says this
# machine has Claude Code, because the skills directory is what we are about to
# create.
@test "install finds a client by its parent, and leaves the others alone" {
  mkdir -p "$HOME/.claude"
  run "$FACTORY" skill install
  [ "$status" -eq 0 ]
  [ -f "$HOME/.claude/skills/factory/SKILL.md" ]
  [ ! -d "$HOME/.codex" ]
}

# A symlink belongs to whatever manages that link; on a haus machine that is
# `haus.ai.skill` and the target is read-only anyway. Skipping is right, and so
# is exiting 0 for it: the end state is holding. The rest of the run still runs.
@test "a symlinked skill is left alone, and the rest of the run still lands" {
  # The link RESOLVES: a dangling one is a different answer, one case down.
  mkdir -p "$HOME/.claude/skills" "$TMP/store/factory"
  ln -s "$TMP/store/factory" "$HOME/.claude/skills/factory"
  run "$FACTORY" skill install --client claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"haus.ai.skill already did"* ]]
  [ -f "$HOME/.claude/skills/nightshift/SKILL.md" ]
  [ -L "$HOME/.claude/skills/factory" ]
}

# The haus machine, whole: every skill is already a read-only symlink haus put
# there. That is the desired end state, so it is a sentence and an exit 0 — a
# non-zero here would have an agent report a broken command and retry with
# more force, against a directory where force corrupts a generation.
@test "a run that finds only symlinks says so, and does not read as a failure" {
  mkdir -p "$TMP/scratch" "$TMP/store/factory" "$TMP/store/nightshift"
  ln -s "$TMP/store/factory" "$TMP/scratch/factory"
  ln -s "$TMP/store/nightshift" "$TMP/scratch/nightshift"
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to install"* ]]
  [[ "$output" == *"--dir"* ]]
  [[ "$output" != *"0 written"* ]]
}

# The other two skips are the caller's request NOT honoured, and they are what
# the exit code is for.
@test "a file that exists and differs is left alone, with the path to diff it against" {
  mkdir -p "$TMP/scratch/factory"
  printf 'someone edited this\n' >"$TMP/scratch/factory/SKILL.md"
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 3 ]
  [[ "$output" == *"exists and differs"* ]]
  [ "$(cat "$TMP/scratch/factory/SKILL.md")" = "someone edited this" ]
}

# ⚠ REGRESSION, and the one the suite could not have caught from a checkout.
# The shipped `ai/` is 444 and `cp` inherits the SOURCE's mode, so every copy
# landed read-only and the second run of the documented command reported a
# refusal nothing had refused. `chmod u+w` is the line haus's own install has
# carried all along; this port dropped it.
@test "installing twice is not a refusal — the copy it wrote stays writable" {
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 0 ]
  [ -w "$TMP/scratch/factory/SKILL.md" ]
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 0 ]
  [[ "$output" == *"2 written, 0 left alone"* ]]
}

# `-L` is true for a link whose target is gone, so a collected store path used
# to read as "haus has this in hand" — a green exit at the one moment the skill
# is unloadable.
@test "a symlink whose target is gone is a refusal, not the end state holding" {
  mkdir -p "$TMP/scratch"
  ln -s "$TMP/nowhere/factory" "$TMP/scratch/factory"
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 3 ]
  [[ "$output" == *"target is gone"* ]]
  [[ "$output" != *"nothing to install"* ]]
}

# `cp` into a directory copies INTO it, so this printed ✓ for a
# `SKILL.md/SKILL.md` no client will ever load.
@test "a directory standing where the file goes is refused, not written into" {
  mkdir -p "$TMP/scratch/factory/SKILL.md"
  run "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 3 ]
  [[ "$output" == *"a directory is in the way"* ]]
  [ ! -e "$TMP/scratch/factory/SKILL.md/SKILL.md" ]
}

# A fourth way to install nothing: a tree with no skills in it reported
# "0 written, 0 left alone" and exited 0, having created nothing.
@test "a tree with no skills is a broken install, not a quiet success" {
  rm -rf "$ROOT/ai"
  run --separate-stderr "$FACTORY" skill install --dir "$TMP/scratch"
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"this install is incomplete"* ]]
  [ ! -d "$TMP/scratch" ]
}

# ⚠ REGRESSION. `mkdir -p` was unguarded, so a read-only client directory ended
# the whole verb at that file: a bare `mkdir: Permission denied` on fd 2, exit
# 1, and every client AFTER this one silently given nothing. The clients are
# walked in a fixed order, so whose skills went missing depended on alphabet.
@test "a client directory that cannot be written does not abandon the ones after it" {
  # Root ignores the mode bits this case sets, which would invert it rather
  # than fail it. CI runs as a normal user; a devcontainer may not.
  [ "$(id -u)" != 0 ] || skip "root writes through the mode bits this case sets"
  mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills"
  chmod a-w "$HOME/.claude/skills"
  run "$FACTORY" skill install
  chmod u+w "$HOME/.claude/skills"
  [ "$status" -eq 3 ]
  [[ "$output" == *"cannot write it"* ]]
  [ -f "$HOME/.codex/skills/factory/SKILL.md" ]
  [ -f "$HOME/.codex/skills/nightshift/SKILL.md" ]
}
