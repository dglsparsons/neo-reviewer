{
  description = "GitHub PR reviewer for Neovim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    crane.url = "github:ipetkov/crane";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, crane, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        craneLib = crane.mkLib pkgs;

        rustSrc = craneLib.cleanCargoSource ./.;

        commonArgs = {
          src = rustSrc;
          pname = "neo-reviewer";
          version = "0.1.0";

          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; lib.optionals stdenv.isDarwin [
            apple-sdk_15
          ] ++ lib.optionals stdenv.isLinux [
            openssl
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        neo-reviewer = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p neo-reviewer";
        });
      in
      {
        packages = {
          inherit neo-reviewer;

          neo-reviewer-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "neo-reviewer";
            version = "0.1.0";
            src = ./.;
            doCheck = false;
          };

          default = neo-reviewer;
        };

        checks = {
          inherit neo-reviewer;

          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "-p neo-reviewer -- -D warnings";
          });

          fmt = craneLib.cargoFmt {
            src = rustSrc;
            pname = "neo-reviewer";
            version = "0.1.0";
          };

          lua-lint = pkgs.runCommand "lua-lint" {
            nativeBuildInputs = [ pkgs.lua-language-server ];
          } ''
            export HOME=$(mktemp -d)
            lua-language-server --check ${./.} --checklevel=Warning
            touch $out
          '';

          lua-fmt = pkgs.runCommand "lua-fmt" {
            nativeBuildInputs = [ pkgs.stylua ];
          } ''
            cd ${./.}
            stylua --check lua/ plugin/ tests/
            touch $out
          '';
        };
      }
    ) // {
      overlays.default = final: prev: {
        neo-reviewer = self.packages.${prev.system}.neo-reviewer;
        vimPlugins = prev.vimPlugins // {
          neo-reviewer-nvim = self.packages.${prev.system}.neo-reviewer-nvim;
        };
      };
    };
}
