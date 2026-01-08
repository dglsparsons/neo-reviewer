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
          pname = "greviewer-cli";
          version = "0.1.0";

          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; lib.optionals stdenv.isDarwin [
            apple-sdk_15
          ] ++ lib.optionals stdenv.isLinux [
            openssl
          ];
        };

        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        greviewer-cli = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;
          cargoExtraArgs = "-p greviewer-cli";
        });
      in
      {
        packages = {
          inherit greviewer-cli;

          greviewer-nvim = pkgs.vimUtils.buildVimPlugin {
            pname = "greviewer";
            version = "0.1.0";
            src = ./.;
            doCheck = false;
          };

          default = greviewer-cli;
        };

        checks = {
          inherit greviewer-cli;

          clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "-p greviewer-cli -- -D warnings";
          });

          fmt = craneLib.cargoFmt {
            src = rustSrc;
          };
        };
      }
    ) // {
      overlays.default = final: prev: {
        greviewer-cli = self.packages.${prev.system}.greviewer-cli;
        vimPlugins = prev.vimPlugins // {
          greviewer-nvim = self.packages.${prev.system}.greviewer-nvim;
        };
      };
    };
}
