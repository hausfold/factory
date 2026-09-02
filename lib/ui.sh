# ui.sh — how `factory` puts a line on screen. Sourced, never executed.
#
# Separate from common.sh, and the reason is `factory --help`: common.sh reads
# the config and so requires `jq` at source time, while the dispatcher wants a
# painted line before it knows whether a verb needs a config at all. Everything
# here is pure bash and costs nothing to source.

# shellcheck shell=bash

: "${FACTORY_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

have() { command -v "$1" >/dev/null 2>&1; }

# ── presentation ──────────────────────────────────────────────────────────────
# snug's bash half, read off the store path this tool's wrapper points at. The
# standard is snug's own README and AGENTS.md; what it buys here is
# one palette resolved from nebelung instead of colours picked by eye, a report
# budgeted against the window it lands in, and one gate that answers `NO_COLOR`,
# a pipe and `TERM=dumb` the same way every other family CLI does.
#
# 🚨 `factory` is a REPORT tool, and that decides the stream. `doctor`'s
# checklist, `tier`'s verdict, `lease status` and every line of a `shift` are
# the thing the user ran the command for — not the tool talking about it — so
# they draw on fd 1, painted and measured for fd 1 (`UI_OUT_*`). `die` is the
# only thing here on fd 2. That split is what keeps `factory shift >> nightly`
# whole and escape-free while a `factory doctor` in a terminal is still painted.
#
# ⚠️ No coprocess. The binary's one advantage over this fallback is a live
# region, and no factory verb draws one: each prints its report and stops. So
# ui.sh is the whole painter here, and `bin/snug` is not on the wrapper's PATH.
ui_load() {
  local p="${FACTORY_UI_SH:-}"
  [ -n "$p" ] && [ -r "$p" ] || return 0
  # shellcheck source=/dev/null
  source "$p"
}
ui_load

# Did it load? A checkout run straight out of the tree — which is every bats
# run and every `./bin/factory` a contributor types — has no wrapper and so no
# `FACTORY_UI_SH`, and must degrade rather than die. ui.sh sets its own gates at
# load; never assume one, hence the `:=` below and not a bare read.
UI_READY=""
type ui_paint_role >/dev/null 2>&1 && UI_READY=1
: "${UI_OUT_AVAIL:=0}"

# The marks are literals here, and that is deliberate: the ROLE comes from snug
# and the GLYPH does not, so a machine with no ui.sh still reads ✓ from ✗. It is
# the colour and the budget that degrade, never the meaning — snug's README,
# "the glyph carries the meaning; the colour is the courtesy".
FACTORY_MARK_OK='✓'
FACTORY_MARK_WARN='⚠'
FACTORY_MARK_BAD='✗'
FACTORY_MARK_INFO='·'

if [ -z "$UI_READY" ]; then
  # The one shape snug's budget gives a stream with no window: every column at
  # its natural width, nothing cut and nothing painted. factory's reports are
  # two columns wide — a label and a value — so the whole layout is: measure the
  # first column, pad to it.
  #
  # ⚠️ `declare -g` is bash 4.2 and this file is the degraded path for a Mac's
  # own `/bin/bash` 3.2 — the clone-and-symlink install with no Nix, which is
  # the one install this fallback exists for. A bare assignment is global here
  # anyway: `ui.sh` is sourced at the top of `bin/factory` before any function
  # runs, and nothing below declares these `local`.
  UI__TROWS=()
  UI_FOLD=()
  ui_col() { :; }
  ui_cell() { printf -v "$1" '%s' "$3"; }
  ui_trow() { local IFS=$'\t'; UI__TROWS+=("$*"); }
  ui_table_clear() { UI__TROWS=(); }
  ui_table_data() {
    local r head rest w=0
    for r in ${UI__TROWS[@]+"${UI__TROWS[@]}"}; do
      head="${r%%$'\t'*}"
      [ "${#head}" -gt "$w" ] && w="${#head}"
    done
    for r in ${UI__TROWS[@]+"${UI__TROWS[@]}"}; do
      head="${r%%$'\t'*}"; rest="${r#*$'\t'}"
      if [ "$rest" = "$r" ]; then printf '   %s\n' "$head"
      else printf '   %-*s  %s\n' "$w" "$head" "${rest//$'\t'/  }"; fi
    done
    UI__TROWS=()
  }
  ui_paint_role() { printf -v "$1" '%s' "$3"; }
  ui_fold() { UI_FOLD=("$2"); }
fi

# out <role> <mark> <text> — one report line on fd 1, folded to fd 1's window.
#
# The mark sits in a three-cell gutter so a ✓ line and a ⚠ line start their text
# in the same column and a folded continuation has somewhere to hang from —
# ui.sh's own gutter, applied to the stream ui.sh's message verbs do not serve.
out() {
  local painted i head pad budget
  ui_paint_role painted "$1" "$2" UI_OUT_
  budget=$(( UI_OUT_AVAIL - 3 ))
  if [ "$budget" -lt 1 ]; then printf '%s  %s\n' "$painted" "$3"; return 0; fi
  ui_fold "$budget" "$3"
  printf -v pad '%*s' 3 ''
  for i in "${!UI_FOLD[@]}"; do
    if [ "$i" -eq 0 ]; then printf -v head '%s%*s' "$painted" 2 ''; else head="$pad"; fi
    printf '%s%s\n' "$head" "${UI_FOLD[$i]}"
  done
  return 0
}

# out_line <role> <mark> <text> — the same line, NOT folded.
#
# For a line whose payload is one unbreakable token: snug's `ui_fold` hard-cuts
# a word longer than the budget, so a CI failure's URL comes out split across a
# hanging indent, unclickable and no longer the one-line shape the foreman's
# skill reads. A terminal's own wrap keeps the token contiguous in the buffer,
# which is the better failure at 60 columns.
out_line() {
  local painted
  ui_paint_role painted "$1" "$2" UI_OUT_
  printf '%s  %s\n' "$painted" "$3"
}

out_ok()   { out ok    "$FACTORY_MARK_OK"   "$*"; }
out_warn() { out warn  "$FACTORY_MARK_WARN" "$*"; }
out_bad()  { out err   "$FACTORY_MARK_BAD"  "$*"; }
out_info() { out muted "$FACTORY_MARK_INFO" "$*"; }
out_bad_url() { out_line err "$FACTORY_MARK_BAD" "$*"; }

# out_head <text> — a section head on fd 1: no mark, so its text starts in the
# same column a mark would, and the rows under it hang off it.
out_head() {
  local painted
  ui_paint_role painted accent "$*" UI_OUT_
  printf '%s\n' "$painted"
}

# Stdout, untouched: a path, a rev, a JSON document — what a caller captures.
out_data() { printf '%s\n' "$*"; }

# The two things here on fd 2, because an error is not the report.
#
# `fail` draws and returns; `die` is `fail` plus the exit code every verb uses
# for "you cannot ask me that". Split because a refusal often owes the reader a
# nudge, and a nudge printed before the error it belongs under reads as a
# non-sequitur.
fail() {
  if [ -n "$UI_READY" ]; then ui_fail "factory: $*"; else printf 'factory: %s\n' "$*" >&2; fi
}
hint() {
  if [ -n "$UI_READY" ]; then ui_hint "$*"; else printf '%s\n' "$*" >&2; fi
}
die() { fail "$*"; exit 2; }
