# factory's agent skills, as a derivation.
#
# TWO skills, one derivation, one directory each:
#
#   ai/SKILL.md            → $out/factory/SKILL.md     the verbs
#   ai/nightshift/SKILL.md → $out/nightshift/SKILL.md  the loop that drives them
#
# The second is not a second copy of the first. `factory` teaches an agent what
# to run when the user says "merge the safe PRs" or "why didn't #212 merge".
# `nightshift` teaches it the one thing that has no verb: the cadence, the fixer
# cap, and what to do with each line a pass printed. The tool is deliberately
# one pass at a time — something has to decide to call it again, and that
# something is judgement rather than a flag.
#
# `$out/<name>/SKILL.md` is the family standard's compliant-tool layout: one
# nesting level, named for the SKILL rather than the tool, so a consumer links a
# directory that is already called the right thing and the TOOL decides those
# names. Skill names are globally unique across the family — they all land in
# one shared skills directory.
{
  lib,
  runCommand,
  bash,
}:

runCommand "factory-skill"
  {
    nativeBuildInputs = [ bash ];
    meta = {
      description = "Agent skills teaching a coding agent to drive factory, and to run its shift unattended";
      license = lib.licenses.mit;
      platforms = lib.platforms.all;
    };
  }
  ''
    # The whole ai/ tree, not two named files: the layout below is DERIVED from
    # it, so a third skill needs no edit here, in test.yml, or in the guard
    # script. Three hardcoded lists is three places to forget one — and a skill
    # that is never checked is one that installs, lists and is never loaded.
    ai=${../ai}

    mkdir -p "$out/factory"
    cp "$ai/SKILL.md" "$out/factory/SKILL.md"

    for dir in "$ai"/*/; do
      [ -f "$dir/SKILL.md" ] || continue
      name="$(basename "$dir")"
      mkdir -p "$out/$name"
      cp "$dir/SKILL.md" "$out/$name/SKILL.md"
    done

    # The guards live in script/check-skills.sh, not here, and that is the whole
    # point: factory's CI runs bats and shellcheck and no Nix, so a guard written
    # into this derivation would run on a developer's machine and nowhere else.
    bash ${../script/check-skills.sh} "$ai" factory
  ''
