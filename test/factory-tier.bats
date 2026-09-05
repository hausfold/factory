#!/usr/bin/env bats
# Unit tests for `libexec/factory-tier` — the filter that decides, with no
# person in the loop, which PRs the shift may merge.
#
# This is the one script in the set whose output causes something with no
# undo-by-default. The README says the merge decision is made by a policy the
# machine's owner typed rather than by a model's read of the diff — a claim
# about a jq expression, which only something that runs it can hold up.
# `test/factory-shift.bats` cannot: it stubs `factory-tier` with a hardcoded
# exit code, so the shift's suite proves what the shift does with a verdict and
# nothing about how a verdict is reached.
#
# The failure that matters here is not a crash either. It is a deny clause that
# stops matching — a nested `| not)` moved one paren, a lost `"i"` flag — and
# whose only symptom is a PR merging at 3 a.m. that a person meant to see. So
# every clause of the filter gets a case that would fail if that clause were
# deleted, and the affirmative is written first: a filter that refuses
# everything is a filter with no observable behaviour at all.
#
# `gh` is stubbed; `jq` is real, because the filter IS a jq program and a stub
# of it would be the thing under test.

bats_require_minimum_version 1.5.0   # `run --separate-stderr`, for the flag refusal

setup() {
  TMP="$BATS_TEST_TMPDIR"
  mkdir -p "$TMP/bin"
  # Run the real tree in place: `factory-tier` resolves `lib/common.sh` by
  # relative path, so it has to be read from a checkout rather than copied out
  # of one.
  TIER="$BATS_TEST_DIRNAME/../libexec/factory-tier"

  PATH="$TMP/bin:$PATH"
  export PATH
  export FACTORY_STATE_DIR="$TMP/state"
  # One org in scope, so a bare repo name resolves — and so the default policy
  # is what every case below is actually testing. A case that needs a different
  # policy writes its own with `config`.
  export FACTORY_CONFIG="$TMP/config.json"
  config '{scope: {orgs: ["hausfold"]}}'
  export TIER_PR_JSON="$TMP/pr.json"
  export TIER_FILES_JSON="$TMP/files.json"
  export TIER_LOGIN=julienmartel

  # The catch-all arm is load-bearing. A `gh` subcommand this stub does not
  # know must be loud: answering an unrecognised call with silence and exit 0
  # is how a check quietly stops being made, which is the whole shape this
  # suite exists to prevent.
  cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"pr view")        cat "$TIER_PR_JSON" ;;
"api user")       printf '%s\n' "$TIER_LOGIN" ;;
"api --paginate") cat "$TIER_FILES_JSON" ;;
*) echo "gh stub: unexpected call: $*" >&2; exit 9 ;;
esac
EOF
  chmod +x "$TMP/bin/gh"

  files "docs/factory.md"
  pr
}

# Writes the machine-local policy file. The argument is a jq expression over an
# empty object, so a case states only the setting it is about.
config() {
  local expr="${1-}"
  [ -n "$expr" ] || expr='{}'
  jq -n "$expr" >"$TMP/config.json"
}

# Writes the paginated files payload. Each argument is a path, or
# `<path>:<status>` where the status is the REST endpoint's own word
# (`modified`, `added`, `renamed`). Also records the count, so `pr` below
# agrees with it by construction and a disagreement is something a test had
# to ask for.
files() {
  local json='[]' arg path status
  for arg in "$@"; do
    path="${arg%%:*}"
    status=modified
    case "$arg" in *:*) status="${arg##*:}" ;; esac
    json=$(jq --arg p "$path" --arg s "$status" '. + [{path: $p, status: $s}]' <<<"$json")
  done
  printf '%s\n' "$json" >"$TMP/files.json"
  NFILES=$#
}

# Writes the `gh pr view` payload. The base is a PR that IS tier 1 in every
# respect, and a case states only its own deviation as a jq assignment — so
# `pr '.isDraft = true'` is unambiguously about drafts, and a test that stops
# being about what it says is a test that had to be edited to get there.
pr() {
  jq -n --argjson n "${NFILES:-1}" '{
    state: "OPEN", isDraft: false, author: {login: "julienmartel"},
    baseRefName: "main", headRefName: "worktree-x",
    headRefOid: "1a2b3c4d5e", mergeable: "MERGEABLE",
    statusCheckRollup: [], changedFiles: $n, additions: 10, deletions: 2
  }' | jq "${1:-.}" >"$TMP/pr.json"
}

# ── the affirmative, and the contract factory-shift reads off it ──────────────

@test "a docs-only PR from a worktree branch is tier 1" {
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
  # Not anchored at the start of the line: the verdict now sits in a three-cell
  # gutter behind its mark. What the mark is, and that it is there at all, is
  # test/presentation.bats's question.
  [[ "$output" == *"tier: 1 "* ]]
}

@test "--json carries the head SHA, because factory-shift merges against it" {
  # `factory-shift` merges with `--match-head-commit "$(jq -r .head)"`. A
  # verdict that stopped carrying `.head` makes every merge fail closed forever
  # and the shift silently stops merging — a two-file contract with nothing else
  # checking it, so both sides are read here.
  #
  # It used to be read off the END of the human line with `${verdict##*head=}`,
  # and that is exactly what a presentation change broke: the moment the verdict
  # gained a mark in its gutter, a sibling strip in the same file stopped
  # matching. A human line is drawn for a person; `--json` is the contract.
  run "$TIER" --json perch 7
  [ "$status" -eq 0 ]
  [ "$(jq -r .head <<<"$output")" = "1a2b3c4d5e" ]
  grep -q "jq -r '.head // \"\"'" "$BATS_TEST_DIRNAME/../libexec/factory-shift"
}

@test "a docs/ path that is not markdown is still tier 1" {
  # `^docs/` is a separate arm from `\.md$` and easy to lose in a rewrite that
  # "simplifies" the filter to markdown. haus's docs/site-data/ is generated
  # JSON that hausfold.co consumes, and it is docs.
  files "docs/site-data/options.json"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "--paths-only answers the file filter alone, before the PR's state" {
  # The two halves are separable on purpose, and a draft is the cheapest proof
  # that the second half is genuinely not consulted.
  pr '.isDraft = true'
  run "$TIER" --paths-only perch 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier: paths ok"* ]]
}

# ── the deny list: one case per clause ────────────────────────────────────────

@test "every exclusion the README's floor names is one the filter actually makes" {
  # A prose exclusion that nothing executes is worse than no exclusion, because
  # it reads as a check: the doc naming a path the filter has never heard of
  # costs nothing until the night it merges one.
  #
  # Both sides are read for the same reason the budget dials are: a pin that
  # only greps the script is re-blessed by the same edit that breaks the doc.
  #
  # ⚠️ The table below is hand-maintained, so it covers the exclusions it LISTS
  # and not "every exclusion the doc names". A new one needs a row here, and in
  # the README, or this case stays green while the pin stops reaching it.
  doc="$BATS_TEST_DIRNAME/../README.md"
  while IFS='|' read -r claim path; do
    grep -qF "$claim" "$doc" || { echo "README no longer names: $claim"; false; }
    files "$path"
    pr
    run "$TIER" perch 7 </dev/null
    [ "$status" -eq 3 ] || { echo "not refused: $path"; false; }
    [[ "$output" == *"touches $path"* ]] || { echo "wrong reason for $path: $output"; false; }
  done <<'EOF'
.github/|.github/ISSUE_TEMPLATE/bug.md
.claude/|.claude/notes.md
.agents/|.agents/README.md
.codex/|.codex/notes.md
.cursor/|.cursor/rules.md
.gemini/|.gemini/notes.md
.opencode/|.opencode/notes.md
content/|content/docs/index.md
EOF
}

@test "the floor holds however the policy is written — an allow-all still refuses it" {
  # The floor is the one part of the policy the config cannot lower, and this
  # is the case that says so: a user who widens `tier1.allow` to everything and
  # empties `tier1.deny` still cannot make a workflow file tier 1.
  config '{scope: {orgs: ["hausfold"]}, tier1: {allow: ["."], deny: []}}'
  files ".github/workflows/release.yml"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"touches .github/workflows/release.yml"* ]]
}

@test "the floor's denies are case-insensitive, because APFS is" {
  # A merged .GitHub/workflows/x.yml IS what Actions runs on this machine, so
  # an odd spelling is the same workflow change wearing a name a case-sensitive
  # filter does not recognise.
  files ".GitHub/workflows/release.yml"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"touches .GitHub/workflows/release.yml"* ]]
}

@test "a steering file is tier 1 — it is policy, and policy is the config's" {
  # The affirmative half of moving AGENTS.md & co off the floor. Written first
  # and kept beside its deny case below, because the risk of the move is not
  # that these stop merging, it is that nothing says whether they should.
  files "AGENTS.md" "docs/CLAUDE.md" "ai/SKILL.md" "GEMINI.md"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
  [[ "$output" == *"tier: 1"* ]]
}

@test "a steering file a policy denies is still refused — a setting, not a gap" {
  # What the floor used to guarantee is now one line of config, and this is the
  # case that says the line still reaches: a user who wants AGENTS.md held for
  # the morning writes it in `tier1.deny` and gets exactly the old behaviour.
  config '{scope: {orgs: ["hausfold"]},
           tier1: {deny: ["(^|/)(AGENTS|CLAUDE|GEMINI|SKILL)\\.md$"]}}'
  files "docs/factory.md" "AGENTS.md"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"touches AGENTS.md"* ]]
}

@test "a path that is neither docs/ nor markdown is refused" {
  files "script/factory-tier"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
}

@test "one bad path among good ones refuses the whole PR" {
  # The filter is over every file, not the first or the majority: a PR is tier
  # 1 only if there is nothing in it a person needed to see.
  files "docs/factory.md" "README.md" ".github/workflows/ci.yml"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"touches .github/workflows/ci.yml"* ]]
}

# ── the structural checks, which are about the file LIST rather than its paths ─

@test "a rename is refused even when the new path is docs-shaped" {
  # A rename is a delete wearing a docs name: `git mv .github/workflows/x.yml
  # docs/x.md` passes every path test and removes a workflow. The REST
  # endpoint is what carries the status at all — GraphQL's file list does not.
  files "docs/moved.md:renamed"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"renames docs/moved.md"* ]]
}

@test "a file list shorter than changedFiles is refused as truncated" {
  # The guard against paging silently stopping: files 101+ never meeting the
  # filter is indistinguishable from their not existing, and this is the only
  # thing that tells them apart.
  files "docs/a.md" "docs/b.md"
  pr '.changedFiles = 5'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"truncated (2 of 5)"* ]]
}

@test "a PR with no files is refused" {
  files
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"no files"* ]]
}

@test "churn over the cap is refused, and the cap is the documented 2000" {
  doc="$BATS_TEST_DIRNAME/../README.md"
  grep -qF '2000' "$doc"
  pr '.additions = 1999 | .deletions = 2'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"2001 changed lines (cap 2000)"* ]]
}

@test "the config moves the cap, and the refusal names the configured number" {
  # The cap is policy, so it lives where the rest of the policy does. There is
  # deliberately no environment override: a variable that widens the filter
  # deciding unattended merges is authority anything in the shift's environment
  # could grant itself.
  config '{scope: {orgs: ["hausfold"]}, tier1: {maxLines: 10}}'
  pr '.additions = 50 | .deletions = 0'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"(cap 10)"* ]]
}

@test "a PR that is not open is refused" {
  pr '.state = "CLOSED"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"not open"* ]]
}

@test "a draft is refused" {
  pr '.isDraft = true'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"draft"* ]]
}

@test "a base other than main is refused" {
  pr '.baseRefName = "release"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"base is not main"* ]]
}

@test "a head that is not a worktree-* branch is refused" {
  # The lane convention is the proxy for "an agent of this user wrote it under
  # the rules in AGENTS.md". A branch named anything else did not come from
  # that path, whatever it contains.
  pr '.headRefName = "patch-1"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"head is not a ^worktree- branch"* ]]
}

@test "a PR by anyone but the authenticated user is refused" {
  # The check is against `gh api user`, not a name written down here, so it
  # keeps meaning "you" on any machine that runs it. A drive-by docs PR from a
  # stranger is the case this exists for.
  pr '.author.login = "someone-else"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"author is not in tier1.authors"* ]]
}

@test "a conflicting PR is refused, and the reason names the state" {
  pr '.mergeable = "CONFLICTING"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"mergeable=CONFLICTING"* ]]
}

@test "UNKNOWN mergeability is refused too — GitHub is still computing it" {
  # Not conflict-free, merely not yet known to be. Mergeability is computed
  # asynchronously after a push, so this is the ordinary state of a PR opened
  # seconds ago, and the next pass will have an answer.
  pr '.mergeable = "UNKNOWN"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"mergeable=UNKNOWN"* ]]
}

# ── checks ────────────────────────────────────────────────────────────────────

@test "an empty check rollup is fine — most docs repos run no CI on PRs" {
  pr '.statusCheckRollup = []'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "a check still running is 'not yet', not 'no'" {
  pr '.statusCheckRollup = [{status: "IN_PROGRESS", conclusion: null}]'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"checks still running"* ]]
}

@test "a red check is refused, and the reason names the conclusion" {
  pr '.statusCheckRollup = [{status: "COMPLETED", conclusion: "FAILURE"}]'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"check concluded FAILURE"* ]]
}

@test "NEUTRAL and SKIPPED conclusions are not red" {
  pr '.statusCheckRollup = [{status: "COMPLETED", conclusion: "SUCCESS"},
                            {status: "COMPLETED", conclusion: "NEUTRAL"},
                            {status: "COMPLETED", conclusion: "SKIPPED"}]'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "a legacy commit status is read from .state when there is no conclusion" {
  # statusCheckRollup mixes two node types: CheckRun carries `conclusion`,
  # StatusContext carries `state`. Reading only the first would score every
  # commit-status check as the default SUCCESS.
  pr '.statusCheckRollup = [{state: "FAILURE"}]'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"check concluded FAILURE"* ]]
}

# ── the CLI contract factory-shift depends on ─────────────────────────────────

@test "a missing argument is exit 2 — usage, not a verdict" {
  # 0, 3 and 2 are three different answers, and factory-shift's `tier-unknown`
  # arm exists because anything outside them means the script died mid-judgement.
  run "$TIER" perch
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
  run "$TIER" perch 7 extra
  [ "$status" -eq 2 ]
}

@test "an unknown flag is refused on fd 2, not read as the repo" {
  # `--jsno` fell through to the positionals and became the repo name, so the
  # refusal blamed scope.orgs for a typo in a flag.
  run --separate-stderr "$TIER" --jsno perch 7
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  [[ "$stderr" == *"unknown flag '--jsno'"* ]]
}

@test "a PR reference that is not a number is a usage error, not gh's" {
  # `gh pr view '#7'` is gh's own error at exit 1 — neither 0, 3 nor 2, so
  # `factory-shift` would file it as tier-unknown rather than as the usage
  # mistake it is.
  run "$TIER" perch '#7'
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a pull request number"* ]]
}

@test "a bare repo name is qualified to the one org in scope, in the verdict too" {
  files ".github/workflows/ci.yml"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"(hausfold/perch#7)"* ]]
}

@test "a bare repo name with no single org in scope is a usage error, not a guess" {
  # Guessing which org a bare name belongs to is how a verdict gets computed
  # against the wrong repo — and a verdict computed against the wrong repo is a
  # merge against the wrong repo.
  config '{scope: {orgs: ["hausfold", "someone-else"]}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not name exactly one org"* ]]

  config '{scope: {repos: ["hausfold/perch"]}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
}

# ── the policy the config sets ────────────────────────────────────────────────

@test "the base branch and the head pattern come from the config" {
  config '{scope: {orgs: ["hausfold"]}, tier1: {base: "trunk", head: "^bot/"}}'
  pr '.baseRefName = "main" | .headRefName = "worktree-x"'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"base is not trunk"* ]]

  pr '.baseRefName = "trunk" | .headRefName = "bot/docs"'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "requireGreen=always refuses a PR that reported no checks at all" {
  # The default forgives an empty rollup, because plenty of docs repos run no
  # CI on PRs. `always` is for the repo where CI is the whole verification
  # story: there, a workflow that failed to TRIGGER is indistinguishable from
  # one that passed, and this is the setting that refuses to guess.
  config '{scope: {orgs: ["hausfold"]}, tier1: {requireGreen: "always"}}'
  pr '.statusCheckRollup = []'
  run "$TIER" perch 7
  [ "$status" -eq 3 ]
  [[ "$output" == *"no checks reported"* ]]
}

@test "requireGreen=never merges a red PR, because that is what it says" {
  config '{scope: {orgs: ["hausfold"]}, tier1: {requireGreen: "never"}}'
  pr '.statusCheckRollup = [{status: "COMPLETED", conclusion: "FAILURE"}]'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "authors [*] is the explicit opt-out, and an empty list is a config error" {
  # `[]` meaning "anyone" is the shape this refuses to have: the widest
  # possible policy must be something a person typed, not something a deleted
  # line produced.
  config '{scope: {orgs: ["hausfold"]}, tier1: {authors: ["*"]}}'
  pr '.author.login = "a-stranger"'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]

  config '{scope: {orgs: ["hausfold"]}, tier1: {authors: []}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.authors is empty"* ]]
}

@test "a named author is honoured without resolving @me" {
  config '{scope: {orgs: ["hausfold"]}, tier1: {authors: ["dependabot[bot]"]}}'
  pr '.author.login = "dependabot[bot]"'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

@test "a config that is not valid JSON is a usage error naming the file" {
  # The alternative is a merge decision made against silently-defaulted policy,
  # which is the widest thing this tool can do by accident.
  printf '{ nope\n' >"$TMP/config.json"
  run "$TIER" hausfold/perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"not valid JSON"* ]]
}

# ── ⚠ regression: a policy the filter cannot run is refused at load ──────────
# Each of these reached the jq filter before this suite, and the filter died on
# it: exit 5, which `factory-shift` files as `tier-unknown` — for every PR, all
# night, under a `doctor` that had read the same file and said ready. Not
# silent, but a night lost to a typo the load could have named.

@test "⚠ a tier1.allow written as a string is refused at load, not a night of tier-unknown" {
  # `"^docs/" | length` is 6, so the "is empty" check passed it, and
  # `$allow | any(...)` then died on iterating a string.
  config '{scope: {orgs: ["hausfold"]}, tier1: {allow: "^docs/"}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.allow must be an array of non-empty strings"* ]]

  # `deny` is added to the floor before the filter runs, and a string and an
  # array cannot be added.
  config '{scope: {orgs: ["hausfold"]}, tier1: {deny: "^foo/"}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.deny must be an array of non-empty strings"* ]]
}

@test "⚠ an empty allow pattern is refused — it matches every path there is" {
  # `[""]` is not `[]`, so the emptiness check let it through, and `test("")`
  # is true of any string: the narrowest-looking policy was the widest one.
  config '{scope: {orgs: ["hausfold"]}, tier1: {allow: [""]}}'
  files ".github/workflows/ci.yml"
  pr
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.allow must be an array of non-empty strings"* ]]
}

@test "⚠ an empty or null tier1.head is refused — it would match every branch" {
  config '{scope: {orgs: ["hausfold"]}, tier1: {head: ""}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.head must be a branch pattern"* ]]

  # `jq -r` prints null as the four letters, and "null" is a regex that matches
  # a branch named after it — a filter that reads as "no head rule" and is
  # actually a rule nobody wrote.
  config '{scope: {orgs: ["hausfold"]}, tier1: {head: null}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"tier1.head must be a branch pattern"* ]]
}

@test "⚠ a pattern jq cannot compile is refused at load, and named" {
  config '{scope: {orgs: ["hausfold"]}, tier1: {allow: ["^docs/", "[md$"]}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a regular expression jq can compile"* ]]
  [[ "$output" == *'"[md$"'* ]]

  # The same engine, in `head` and in `deny`: one check over all three lists.
  config '{scope: {orgs: ["hausfold"]}, tier1: {head: "^(worktree-"}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *'"^(worktree-"'* ]]

  config '{scope: {orgs: ["hausfold"]}, tier1: {deny: ["*.lock"]}}'
  run "$TIER" perch 7
  [ "$status" -eq 2 ]
  [[ "$output" == *'"*.lock"'* ]]
}

@test "a policy that compiles still runs — the compile check refuses nothing else" {
  # The control: every pattern the default policy ships, plus a deny with a
  # character class and an anchor, through the same load.
  config '{scope: {orgs: ["hausfold"]}, tier1: {deny: ["^[Cc]hangelog\\.md$", "\\.lock$"]}}'
  run "$TIER" perch 7
  [ "$status" -eq 0 ]
}

# ── --json, the shape an agent reads ──────────────────────────────────────────

@test "--json carries the verdict, the head SHA and a null reason" {
  run "$TIER" --json perch 7
  [ "$status" -eq 0 ]
  [ "$(jq -r .tier <<<"$output")" = 1 ]
  [ "$(jq -r .repo <<<"$output")" = hausfold/perch ]
  [ "$(jq -r .head <<<"$output")" = 1a2b3c4d5e ]
  [ "$(jq -r .reason <<<"$output")" = null ]
}

@test "--json on a refusal carries the reason and a null tier" {
  files ".github/workflows/ci.yml"
  pr
  run "$TIER" --json perch 7
  [ "$status" -eq 3 ]
  [ "$(jq -r .tier <<<"$output")" = null ]
  [ "$(jq -r .reason <<<"$output")" = "touches .github/workflows/ci.yml" ]
}
