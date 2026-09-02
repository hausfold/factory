{
  description = "factory — merge the pull requests code alone can vouch for, while nobody is watching";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  # snug is the family's presentation runtime — the standard is the workshop's
  # `docs/cli-presentation.md`, and this is the half a bash caller can reach.
  # factory reads `share/ui.sh` off snug's store path, the way haus does, and
  # that path is all it takes: `bin/snug` is NOT put on PATH here, because the
  # binary's one advantage over the fallback is a live region drawn from a
  # coprocess, and factory draws no live region. Its verbs each print a report
  # and stop.
  #
  # `follows` is not decoration: snug's overlay hands back a package built from
  # snug's OWN nixpkgs, so without this factory evaluates and realises a second
  # nixpkgs and a second Go toolchain to produce one ~2 MB binary it only wants
  # one text file out of.
  inputs.snug = {
    url = "github:hausfold/snug";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    { self, nixpkgs, snug }:
    let
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
      version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./VERSION);
    in
    {
      packages = forAll (pkgs: rec {
        default = factory;

        factory = pkgs.stdenvNoCC.mkDerivation {
          pname = "factory";
          inherit version;
          src = ./.;
          nativeBuildInputs = [ pkgs.makeWrapper ];

          # The tree ships whole, because `bin/factory` finds its siblings by
          # walking up from its own path: the libexec scripts it execs, the
          # library they source, the VERSION they report and the skills `factory
          # skill` prints. Splitting them would mean teaching four scripts a
          # store layout, where copying the tree teaches them nothing.
          installPhase = ''
            runHook preInstall
            mkdir -p "$out/share/factory" "$out/bin"
            cp -r bin libexec lib ai share VERSION "$out/share/factory/"
            # Wrapped rather than symlinked: `jq` and `gh` are hard
            # dependencies, and a user who installed this without them should
            # get a working tool rather than the `jq is required` line the
            # script would otherwise print on every verb.
            # `--set-default` and not `--set`: a workshop checkout points this
            # at snug's working tree to feel a palette change without a
            # release, and the store path is what everyone else gets.
            makeWrapper "$out/share/factory/bin/factory" "$out/bin/factory" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.jq pkgs.gh ]} \
              --set-default FACTORY_UI_SH ${snug.packages.${pkgs.stdenv.hostPlatform.system}.default}/share/ui.sh
            runHook postInstall
          '';

          doCheck = true;
          checkInputs = [ pkgs.bats pkgs.jq ];
          checkPhase = ''
            runHook preCheck
            patchShebangs bin libexec script
            ${pkgs.bash}/bin/bash script/check-skills.sh ai factory
            runHook postCheck
          '';

          meta = with pkgs.lib; {
            description = "Merge the pull requests code alone can vouch for, while nobody is watching";
            homepage = "https://github.com/hausfold/factory";
            license = licenses.mit;
            mainProgram = "factory";
            platforms = platforms.unix;
          };
        };

        factory-skill = pkgs.callPackage ./nix/skill.nix { };
      });

      # The overlay consumers take, so `pkgs.factory` is the CLI wherever this
      # flake is an input.
      overlays.default = final: _prev: {
        factory = self.packages.${final.system}.factory;
        factory-skill = self.packages.${final.system}.factory-skill;
      };

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.bats
            pkgs.shellcheck
            pkgs.jq
            pkgs.gh
            # Not because anything execs it — nothing does — but because
            # `test/presentation.bats` finds `share/ui.sh` off the store path of
            # whatever `snug` is on PATH, and skips its painted cases without
            # one. A shell where half the presentation suite silently skips is
            # the shape that lets the painted path rot.
            snug.packages.${pkgs.stdenv.hostPlatform.system}.default
          ];
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt-rfc-style);
    };
}
