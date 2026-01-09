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
          pname = "greviewer";
          version = "0.1.0";

          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; lib.optionals stdenv.isDarwin [
            apple-sdk_15
          ] ++ lib.optionals stdenv.isLinux [
            openssl
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        greviewer = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p greviewer";
        });
      in
      {
        packages = {
          inherit greviewer;

          greviewer-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "greviewer";
            version = "0.1.0";
            src = ./.;
            doCheck = false;
          };

          default = greviewer;
        };

        checks = {
          inherit greviewer;

          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "-p greviewer -- -D warnings";
          });

          fmt = craneLib.cargoFmt {
            src = rustSrc;
            pname = "greviewer";
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
        greviewer = self.packages.${prev.system}.greviewer;
        vimPlugins = prev.vimPlugins // {
          greviewer-nvim = self.packages.${prev.system}.greviewer-nvim;
        };
      };
    };
}
