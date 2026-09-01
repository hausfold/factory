#!/usr/bin/env bash
# The guards on factory's agent skills — one copy, run from two places.
#
# Every failure here is INVISIBLE at runtime. A skill whose frontmatter is
# missing, unterminated, or whose `name:` disagrees with its directory installs
# fine, lists fine, and is never loaded — indistinguishable, from the user's
# side, from the agent not knowing scruff exists. So it has to be a build failure,
# and it has to fire in CI.
#
# Which is why this is a script and not a `runCommand` body: factory's CI runs
# bats and shellcheck and no Nix at all, so guards living only in nix/skill.nix
# would run on a developer's machine and nowhere else. nix/skill.nix calls this,
# and `test.yml` calls it directly.
#
# It DISCOVERS the skills rather than being handed a list, and that is the point:
# a hardcoded list here plus a hardcoded list in nix/skill.nix plus a third in
# test.yml is three places to forget a new skill, and forgetting it in the CI
# copy reinstates exactly the gap this script was extracted to close.
#
# Usage: script/check-skills.sh <ai-dir> <tool-name>
#
#   <ai-dir>/SKILL.md        → checked as <tool-name>   (the tool's own skill)
#   <ai-dir>/*/SKILL.md      → checked as its directory name
set -euo pipefail

status=0
bad() { printf '%s\n' "$*" >&2; status=1; }

[ "$#" -eq 2 ] || {
  printf 'usage: check-skills.sh <ai-dir> <tool-name>\n' >&2
  exit 2
}
root="$1" tool="$2"
[ -d "$root" ] || { printf 'check-skills.sh: no such directory: %s\n' "$root" >&2; exit 2; }

# name<TAB>path, the tool's own first.
skills="$(printf '%s\t%s\n' "$tool" "$root/SKILL.md")"
for dir in "$root"/*/; do
  [ -f "$dir/SKILL.md" ] || continue
  skills="$skills
$(printf '%s\t%s' "$(basename "$dir")" "$dir/SKILL.md")"
done

# At least the tool's own has to be there — an empty run must not pass.
[ -f "$root/SKILL.md" ] || { printf 'check-skills.sh: no %s/SKILL.md\n' "$root" >&2; exit 2; }

while IFS="$(printf '\t')" read -r name skill; do
  [ -n "$name" ] || continue

  [ -f "$skill" ] || { bad "$name: no SKILL.md at $skill"; continue; }

  # The frontmatter, and ONLY the frontmatter. Every client routes on `name` and
  # `description`; keys that appear further down the body are prose.
  if ! head -1 "$skill" | grep -qx -- '---'; then
    bad "$name: SKILL.md does not open with YAML frontmatter"
    continue
  fi
  front="$(tail -n +2 "$skill" | sed -n '1,/^---$/p')"
  printf '%s\n' "$front" | grep -qx -- '---' \
    || { bad "$name: SKILL.md frontmatter block is never closed"; continue; }

  # The directory name and the `name:` key are two identifiers for one skill —
  # the path a client scans, and the string it routes on. A mismatch installs a
  # skill under a name nothing ever asks for.
  printf '%s\n' "$front" | grep -qx "name: $name" \
    || bad "$name: SKILL.md has no 'name: $name' line"

  # The description is what every client matches the user's words against, so
  # the guard is about its CONTENT, not its typography: both a single line and a
  # folded scalar (`description: >-` plus an indented body) are checked, by
  # folding the block back into one string first. scruff's copy of this script
  # demands one physical line instead — a stricter rule that would make a
  # description long enough to route on unreadable in the file.
  desc="$(printf '%s\n' "$front" | awk '
    /^description:/ { d = substr($0, index($0, ":") + 1); inblock = 1; next }
    inblock && /^[a-zA-Z_-]+:/ { inblock = 0 }
    inblock { sub(/^[ \t]+/, " "); d = d $0 }
    END { print d }')"
  [ "${#desc}" -ge 80 ] \
    || bad "$name: SKILL.md description is missing or too short to route on (${#desc} chars)"

  # A routing document that grew into a manual stops being read as one.
  lines=$(wc -l < "$skill")
  [ "$lines" -le 150 ] \
    || bad "$name: SKILL.md is $lines lines; the standard caps a skill at 150"
# A pipe would put this loop in a subshell and throw `status` away with it, so
# every failure would print and the script would still exit 0.
done <<EOF
$skills
EOF

exit "$status"
