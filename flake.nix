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

          rust-tests = craneLib.cargoTest (commonArgs // {
            inherit cargoArtifacts;
            cargoTestExtraArgs = "-p neo-reviewer --all-targets";
          });

          fmt = craneLib.cargoFmt {
            src = rustSrc;
            pname = "neo-reviewer";
            version = "0.1.0";
          };

          lua-lint = pkgs.runCommand "lua-lint" {
            nativeBuildInputs = [ pkgs.lua-language-server pkgs.neovim-unwrapped ];
          } ''
            export HOME=$(mktemp -d)
            export VIMRUNTIME=${pkgs.neovim-unwrapped}/share/nvim/runtime
            lua-language-server --check ${./.} --checklevel=Hint --configpath ${./.}/.luarc.json
            touch $out
          '';

          lua-fmt = pkgs.runCommand "lua-fmt" {
            nativeBuildInputs = [ pkgs.stylua ];
          } ''
            cd ${./.}
            stylua --check lua/
            touch $out
          '';

          lua-tests = pkgs.runCommand "lua-tests" {
            nativeBuildInputs = [ pkgs.neovim pkgs.vimPlugins.plenary-nvim ];
          } ''
            export HOME=$(mktemp -d)
            mkdir -p "$HOME/.local/share/nvim/site/pack/test/start"
            # minimal_init.lua searches this path for plenary.nvim.
            plenary_root="${pkgs.vimPlugins.plenary-nvim}"
            plenary_path="$plenary_root"
            if [ -d "$plenary_root/share/vim-plugins/plenary.nvim" ]; then
              plenary_path="$plenary_root/share/vim-plugins/plenary.nvim"
            elif [ -d "$plenary_root/share/vim-plugins/plenary-nvim" ]; then
              plenary_path="$plenary_root/share/vim-plugins/plenary-nvim"
            fi
            ln -s "$plenary_path" "$HOME/.local/share/nvim/site/pack/test/start/plenary.nvim"

            cd ${./.}
            nvim --headless -u lua/tests/minimal_init.lua \
              -c "PlenaryBustedDirectory lua/tests/plenary/ {minimal_init = 'lua/tests/minimal_init.lua', sequential = true}" \
              -c "qa"
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
