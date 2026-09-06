# factory's agent skills, as a derivation.
#
# ONE skill today, one directory, and a layout that takes more without an edit:
#
#   ai/SKILL.md          → $out/factory/SKILL.md   the verbs
#   ai/<name>/SKILL.md   → $out/<name>/SKILL.md    any sibling, discovered
#
# There used to be a second, `nightshift`: the loop that called `factory shift`
# on a cadence and applied four rules to every CI-RED line. Its judgement was
# four string checks and a retry counter, so it is code now — `factory watchdog
# run` is the runner, started by `lease grant` — and the skill is gone. The
# loop below still walks `ai/*/` so a real second skill needs no edit here.
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
