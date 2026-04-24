{
  description = "tip-server: Typst + LaTeX preview server for the TIP Emacs mode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # LaTeX is NOT bundled with the distributed `tip-server` — the
        # expectation is that users already have a working TeX install
        # (it's why they're using a LaTeX backend in the first place).
        # We only bundle texlive for development + CI, where a pinned
        # scheme-full + dvisvgm gives reproducible test outcomes across
        # machines and exercises the widest package surface.
        #
        # `dvisvgm` lives inside the texlive tree on nixpkgs, so it
        # goes through `texlive.combine` alongside the .sty packages.
        testLatexEnv = pkgs.texlive.combine {
          inherit (pkgs.texlive) scheme-full dvisvgm;
        };

        tip-server = pkgs.rustPlatform.buildRustPackage {
          pname = "tip-server";
          version = "0.1.0";
          src = ./tip-server;

          cargoLock = {
            lockFile = ./tip-server/Cargo.lock;
          };

          # Only build the tip-server binary (the workspace also has
          # tip-core-typst, tip-core-latex, tip-protocol as libraries
          # those get compiled transitively).
          cargoBuildFlags = [ "-p" "tip-server" ];
          # Running the full workspace test suite at build time would
          # require a working LaTeX install; gated behind a separate
          # `checks` output instead.
          doCheck = false;

          # `perl` is needed by openssl-src at build time (the workspace
          # uses openssl's "vendored" feature so release binaries don't
          # depend on system OpenSSL at runtime).
          nativeBuildInputs = [ pkgs.pkg-config pkgs.perl ];
          buildInputs = [ ];

          meta = with pkgs.lib; {
            description = "Typst + LaTeX preview server for TIP Emacs mode";
            mainProgram = "tip-server";
            license = licenses.mit;  # adjust when LICENSE lands
            platforms = platforms.unix;
          };
        };

      in {
        packages = {
          default = tip-server;
          tip-server = tip-server;
        };

        apps.default = {
          type = "app";
          program = "${tip-server}/bin/tip-server";
        };

        # `nix develop` gives a reproducible build+test environment:
        # rust toolchain, LaTeX pipeline, emacs for batch tests.
        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.cargo
            pkgs.rustc
            pkgs.rustfmt
            pkgs.clippy
            pkgs.rust-analyzer
            # pgtk build = pure GTK = native Wayland.  Interactive GUI
            # tests (childframe previews, visual-test.el) need a real
            # display; emacs-nox can't run them.  CI uses emacs-nox via
            # the `emacs-batch-test` check below.
            pkgs.emacs-pgtk
            pkgs.pkg-config
            pkgs.perl
            testLatexEnv
          ];
        };

        # `nix flake check` runs the full cargo test suite + emacs
        # batch tests in the pinned env.  This is how CI verifies that
        # everyone sees the same outcomes across machines.
        checks = {
          cargo-test = pkgs.stdenv.mkDerivation {
            name = "tip-server-cargo-test";
            src = ./tip-server;
            nativeBuildInputs = [ pkgs.cargo pkgs.rustc pkgs.perl testLatexEnv ];
            buildPhase = ''
              export HOME=$TMPDIR
              export CARGO_HOME=$TMPDIR/.cargo
              cargo test --workspace --offline || cargo test --workspace
            '';
            installPhase = "touch $out";
          };

          emacs-batch-test = pkgs.stdenv.mkDerivation {
            name = "tip-emacs-batch-test";
            src = ./.;
            nativeBuildInputs = [ pkgs.emacs-nox ];
            buildPhase = ''
              export HOME=$TMPDIR
              emacs --batch -l test-tip.el
            '';
            installPhase = "touch $out";
          };
        };
      });
}
