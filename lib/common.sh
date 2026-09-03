# common.sh — config, platform shims, logging and notification for every
# `factory` verb. Sourced, never executed.
#
# THE CONFIG IS MACHINE-LOCAL, AND THAT IS A SAFETY PROPERTY, not a packaging
# choice. The policy file decides which PRs merge unattended, so a copy of it
# inside a watched repo would be a file a PR could edit to widen the filter
# that judges it. Same argument the lease already makes about itself: authority
# to merge belongs to this machine's owner having typed it, never to a tree the
# factory is reading. It also describes a FLEET — every repo one shift walks —
# so a per-repo file would be the wrong shape even if it were safe.
#
# Order: $FACTORY_CONFIG, then $XDG_CONFIG_HOME/factory/config.json, then the
# built-in defaults below. The file is deep-merged over the defaults (objects
# merge, arrays replace), so a config naming one key keeps every other default.

# shellcheck shell=bash

: "${FACTORY_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
FACTORY_STATE_DIR="${FACTORY_STATE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/factory}"
FACTORY_CONFIG_PATH="${FACTORY_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/factory/config.json}"
# Read by the scripts that source this file, not by this file.
# shellcheck disable=SC2034
FACTORY_VERSION="$(cat "$FACTORY_HOME/VERSION" 2>/dev/null || echo 0.0.0)"

# Presentation — the report verbs (`out_ok`, `out_head`, `die`) and snug's
# painter behind them. Sourced first because `die` is what a bad config uses.
# shellcheck source=lib/ui.sh
. "$FACTORY_HOME/lib/ui.sh"

have jq || die "jq is required (brew install jq)"

# ── the floor ─────────────────────────────────────────────────────────────────
# Deny patterns no config can switch off, applied on top of whatever the policy
# denies. What is left here is the paths that are not prose at all:
#
#   CI and client directories — a workflow file merged unattended is arbitrary
#   code with the repo's own token, which is the whole ballgame. `.claude/` and
#   its siblings are the same argument, one directory per client.
#
#   `content/` — a repo whose main deploys a public site turns a docs merge
#   into a publish, and a user-facing publish is always gated. Denied for every
#   repo rather than scoped to the one name where the path exists today, since
#   a refusal only queues the PR for the morning, which is where it would have
#   been anyway.
#
# Agent-steering files (AGENTS.md, CLAUDE.md, GEMINI.md, SKILL.md) were here
# and are NOT any more: a machine whose worktree PRs are the owner's own edits
# to its own instructions was queueing every one of them for a morning that
# added nothing to reading them in the PR. They are ordinary policy now — a
# `tier1.deny` entry holds them for anyone who wants them held, which is the
# difference between a floor and a setting, and the config is the one file that
# reads back what it will do.
#
# Case-insensitive because APFS is: a merged .GitHub/workflows/x.yml IS what
# Actions runs, and a clause that only knows one spelling has already stopped
# matching.
FACTORY_FLOOR_DENY='[
  "^\\.(github|claude|agents|codex|cursor|gemini|opencode)/",
  "^content/"
]'

# ── defaults ──────────────────────────────────────────────────────────────────
# Every default fails CLOSED: no repos in scope is a config error rather than a
# quiet pass, no budget feed is `fixer: no`, and the tier filter starts at
# docs-only. Widening any of them is the user's typed decision, in one file
# `factory config print` reads back to them.
factory_defaults() {
  cat <<'JSON'
{
  "scope":   { "orgs": [], "repos": [], "exclude": [], "archived": false, "limit": 100 },
  "tier1":   { "allow": ["^docs/", "\\.md$"],
               "deny": [],
               "base": "main",
               "head": "^worktree-",
               "authors": ["@me"],
               "maxLines": 2000,
               "requireGreen": "if-present",
               "mergeMethod": "squash" },
  "afterMerge": { "workdir": null, "commands": [] },
  "budget":  { "mode": "metered",
               "feed": null,
               "ceiling": 95,
               "reserve": 70,
               "fixer": 5,
               "window5hMax": 80 },
  "notify":  { "mode": "auto", "command": [], "source": "factory" },
  "watchdog": { "stale": 2700, "dead": 5400, "interval": 300 }
}
JSON
}

# The effective config, defaults deep-merged with the file. `factory_load` fills
# a global in the CURRENT shell and every reader below reads that global, so the
# merge costs one jq per process rather than one per lookup — which matters
# because `cfg` is almost always called inside a command substitution, and a
# cache written in a subshell is a cache thrown away.
FACTORY_CFG=""
factory_load() {
  [ -z "$FACTORY_CFG" ] || return 0
  local file="{}"
  if [ -f "$FACTORY_CONFIG_PATH" ]; then
    jq -e . "$FACTORY_CONFIG_PATH" >/dev/null 2>&1 ||
      die "config is not valid JSON: $FACTORY_CONFIG_PATH"
    file="$(cat "$FACTORY_CONFIG_PATH")"
  fi
  # `*` is jq's recursive object merge: nested objects merge key by key, and
  # arrays REPLACE rather than concatenate — so a config naming `tier1.allow`
  # sets it outright instead of quietly inheriting the default patterns too.
  FACTORY_CFG="$(factory_defaults | jq -c --argjson f "$file" '. * $f')" ||
    die "could not merge $FACTORY_CONFIG_PATH over the defaults"
  factory_validate
}

# Read one key: `cfg .tier1.base`
cfg() { factory_load; printf '%s' "$FACTORY_CFG" | jq -r "$1"; }
cfgj() { factory_load; printf '%s' "$FACTORY_CFG" | jq -c "$1"; }

# Every value the rest of the tool computes on is checked HERE, once, and a bad
# one is a usage error at startup rather than a pass that half-ran. A policy
# whose numbers are nonsense must never reach the merge loop and discover it.
factory_validate() {
  local err
  err="$(printf '%s' "$FACTORY_CFG" | jq -r '
    [ (if (.tier1.allow | length) == 0 then "tier1.allow is empty — no PR could ever be tier 1" else empty end),
      (if (.tier1.authors | length) == 0 then "tier1.authors is empty — write [\"*\"] if you really mean anyone" else empty end),
      (if (.tier1.maxLines | type) != "number" or .tier1.maxLines < 1 then "tier1.maxLines must be a positive number" else empty end),
      (if (.tier1.requireGreen | IN("if-present","always","never") | not) then "tier1.requireGreen must be if-present, always or never" else empty end),
      (if (.tier1.mergeMethod | IN("squash","merge","rebase") | not) then "tier1.mergeMethod must be squash, merge or rebase" else empty end),
      (if (.tier1.base | type) != "string" or (.tier1.base | length) == 0 then "tier1.base must be a branch name" else empty end),
      (if (.scope.archived | type) != "boolean" then "scope.archived must be true or false" else empty end),
      (if (.scope.limit | type) != "number" or .scope.limit < 1 then "scope.limit must be a positive number" else empty end),
      (if (.budget.mode | IN("metered","unmetered") | not) then "budget.mode must be metered or unmetered" else empty end),
      (if (.notify.mode | IN("auto","command","off") | not) then "notify.mode must be auto, command or off" else empty end),
      (if (.notify.command | type) != "array" then "notify.command must be an array of argv words, not a string" else empty end),
      (if .notify.mode == "command" and (.notify.command | type) == "array" and (.notify.command | length) == 0 then "notify.mode is command with an empty notify.command — nothing would ever be sent; write \"off\" if that is what you mean" else empty end),
      (if (.notify.source | type) != "string" or (.notify.source | length) == 0 then "notify.source must be a non-empty string — it is what a notification rule matches on" else empty end),
      ([.budget.ceiling, .budget.reserve, .budget.fixer, .budget.window5hMax] | map(select(type != "number")) | if length > 0 then "budget thresholds must be numbers" else empty end),
      ([.watchdog.stale, .watchdog.dead, .watchdog.interval] | map(select(type != "number" or . < 1)) | if length > 0 then "watchdog thresholds must be positive numbers" else empty end),
      (if .watchdog.dead <= .watchdog.stale then "watchdog.dead must be greater than watchdog.stale" else empty end)
    ] | join("; ")')"
  [ -z "$err" ] || die "$err  (in $FACTORY_CONFIG_PATH)"
}

# The policy digest, printed once per pass. A machine-local policy file trades
# in-repo review for this: which filter merged tonight is a fact the morning can
# read off the log rather than infer from a file that has since been edited.
factory_policy_digest() {
  factory_load
  printf '%s' "$FACTORY_CFG" | jq -cS '{tier1, scope, floor: $floor}' --argjson floor "$FACTORY_FLOOR_DENY" |
    { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-8
}

# ── platform shims ────────────────────────────────────────────────────────────
# `stat` and `date` are spelled differently by BSD (the Mac that holds the
# lease) and GNU (the Linux runner the suites use), and the obvious
# `bsd_form || gnu_form` is UNSAFE for `stat`: GNU's `-f` is --file-system, so
# `stat -f %m FILE` prints a filesystem line on STDOUT, complains to stderr and
# exits 1 — the fallback then runs too and APPENDS the real answer to the
# garbage. So each flavour is probed once, by asking for an answer whose correct
# value is known.
if [ -n "$(stat -c %Y / 2>/dev/null)" ] && [ -z "$(stat -c %Y / 2>/dev/null | tr -d '0-9')" ]; then
  FACTORY_STAT_KIND=gnu
else
  FACTORY_STAT_KIND=bsd
fi
# BSD reads `date -r N` as an epoch; GNU reads it as a file to take the mtime
# of, so only BSD answers 1.
if [ "$(date -r 1 +%s 2>/dev/null)" = 1 ]; then FACTORY_DATE_KIND=bsd; else FACTORY_DATE_KIND=gnu; fi

mtime() {
  case "$FACTORY_STAT_KIND" in
  gnu) stat -c %Y "$1" 2>/dev/null ;;
  *) stat -f %m "$1" 2>/dev/null ;;
  esac
}
fmt() { # fmt <epoch> <strftime format>
  case "$FACTORY_DATE_KIND" in
  gnu) date -d "@$1" "$2" 2>/dev/null ;;
  *) date -r "$1" "$2" 2>/dev/null ;;
  esac
}
at() { fmt "$1" '+%a %H:%M'; }
stampfmt() { fmt "$1" '+%Y%m%d%H%M.%S'; } # `touch -t`, which both spell alike
num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# One event is one line in the log, so anything quoted into one has to become
# one: a `gh` error is often several, and a wrapped line stops `grep`ing as an
# event. Truncated because the discriminating part is at the front
# (`connection reset by peer`, `HTTP 403`, `Bad credentials`).
oneline() { printf '%s' "$*" | tr '\n\t' '  ' | tr -s ' ' | cut -c1-160; }

# ── notification ──────────────────────────────────────────────────────────────
# `auto` uses trill when it is installed and does nothing when it is not, so the
# family's machines card and a stranger's stays quiet without configuring
# anything. `command` runs any argv the user names, with the event appended as
# <kind> <title> [url] — no flag shape assumed, so `notify-send`, a shell
# function or a webhook curl all fit. Failure is always swallowed: a card nobody
# could draw must never take down the pass it was reporting on.
notify() { # notify <kind> <title> [url]
  local mode; mode="$(cfg .notify.mode)"
  case "$mode" in
  off) return 0 ;;
  command)
    local -a argv=()
    while IFS= read -r a; do argv+=("$a"); done < <(cfg '.notify.command[]')
    [ "${#argv[@]}" -gt 0 ] || return 0
    "${argv[@]}" "$1" "$2" ${3:+"$3"} >/dev/null 2>&1 || true
    ;;
  *)
    have trill || return 0
    trill send --source "$(cfg .notify.source)" --kind "$1" --title "$2" ${3:+--url "$3"} >/dev/null 2>&1 || true
    ;;
  esac
}
