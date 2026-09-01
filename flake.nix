{
  description = "factory — merge the pull requests code alone can vouch for, while nobody is watching";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { self, nixpkgs }:
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
            makeWrapper "$out/share/factory/bin/factory" "$out/bin/factory" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.jq pkgs.gh ]}
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
          packages = with pkgs; [
            bats
            shellcheck
            jq
            gh
          ];
        };
      });

      formatter = forAll (pkgs: pkgs.nixfmt-rfc-style);
    };
}
