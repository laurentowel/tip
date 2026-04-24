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

        # Musl-static build of the same binary.  Target switched via
        # pkgsCross.musl64 (so rustc, linker, and openssl are all musl
        # variants — no glibc linkage).  The resulting binary runs on
        # any x86_64 Linux without Nix or matching glibc — that's the
        # artifact we ship on GitHub releases.
        # Musl build wrapped in +crt-static so libc itself is linked
        # statically.  Without this, rustc's musl target emits a PIE
        # that dynamically links to musl's libc.so — which defeats
        # the point, since that .so only lives in the nix store.
        mkStaticTipServer = crossPkgs: crossPkgs.rustPlatform.buildRustPackage {
          pname = "tip-server-static";
          version = "0.1.0";
          src = ./tip-server;
          cargoLock = { lockFile = ./tip-server/Cargo.lock; };
          cargoBuildFlags = [ "-p" "tip-server" ];
          doCheck = false;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.perl ];
          buildInputs = [ ];
          # +crt-static → libc/libgcc_s statically linked.  Result:
          # single file that runs on any Linux of the matching arch
          # with no external .so dependencies.
          RUSTFLAGS = "-C target-feature=+crt-static";
          meta = tip-server.meta // { description = "tip-server (musl-static)"; };
        };
        tip-server-static = mkStaticTipServer pkgs.pkgsCross.musl64;
        tip-server-static-aarch64 =
          mkStaticTipServer pkgs.pkgsCross.aarch64-multiplatform-musl;

        # ----- demo: GUI emacs with tip-mode rendering live -----
        #
        # `nix run .#demo` opens emacs-pgtk (native Wayland) with
        # tip-server on PATH, typst-ts-mode installed, the typst
        # tree-sitter grammar wired up, and two buffers side by side
        # (a .typ and a .tex, both with tip-mode live).  Zero host
        # config — every bit is pinned by the flake.

        # typst-ts-mode isn't in nixpkgs' melpaPackages snapshot yet, so
        # fetch it directly from codeberg and trivial-build it.
        typst-ts-mode = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).trivialBuild {
          pname = "typst-ts-mode";
          version = "0-unstable-2026-04";
          src = pkgs.fetchFromGitea {
            domain = "codeberg.org";
            owner = "meow_king";
            repo = "typst-ts-mode";
            rev = "278562d702de429f5c4369c007913ca0ef1584f3";
            hash = "sha256-B1GAyYWLUipsTD7DHH7TSZjWtp1gru4YdOXqXmPeedU=";
          };
          # All .el sit at the repo root.
          postUnpack = "";
          meta.description = "Major mode for Typst, tree-sitter based";
        };

        # The typst grammar derivation outputs `$out/parser` as a .so
        # file.  Emacs' treesit-extra-load-path expects a directory
        # containing `libtree-sitter-LANG.so`, so symlink it into shape.
        typstGrammarDir = pkgs.runCommand "tip-typst-grammar-dir" { } ''
          mkdir -p $out
          ln -s ${pkgs.tree-sitter-grammars.tree-sitter-typst}/parser \
                $out/libtree-sitter-typst.so
        '';

        demoEmacs = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages
          (ep: [ typst-ts-mode ]);

        # Typst and LaTeX demos show the SAME math, just translated into
        # each language's syntax.  Kept as separate files in demo/ so
        # edits go through normal git diffs (and don't hit nix's
        # indented-string apostrophe/escape gotchas).  Any change to
        # one file should be mirrored in the other.
        demoTypst = ./demo/tip-demo.typ;
        demoLatex = ./demo/tip-demo.tex;

        demoInit = pkgs.writeText "tip-demo-init.el" ''
          ;; Minimal init for the tip-mode demo.  Everything outside
          ;; this file is flake-pinned.
          (setq inhibit-startup-screen t
                make-backup-files nil
                auto-save-default nil
                frame-title-format "tip-mode demo (Typst | LaTeX)")
          (add-to-list 'treesit-extra-load-path "${typstGrammarDir}/")
          (add-to-list 'load-path "${toString ./.}")
          (require 'typst-ts-mode)
          (require 'tip)
          (require 'tip-typst)
          (require 'tip-latex)
          ;; With -Q the typst-ts-mode autoload isn't registered —
          ;; do it explicitly so `.typ` buffers get the mode.
          (add-to-list 'auto-mode-alist '("\\.typ\\'" . typst-ts-mode))
          (add-to-list 'auto-mode-alist '("\\.tex\\'" . latex-mode))
          ;; Open typst on the left, latex on the right.
          (find-file "${demoTypst}")
          (split-window-right)
          (other-window 1)
          (find-file "${demoLatex}")
          (other-window 1)
          ;; Enable tip-mode in both buffers.  `set-auto-mode' is
          ;; harmless on buffers that already picked the right mode;
          ;; it's a safety net in case the find-file above ran before
          ;; auto-mode-alist was populated.
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (buffer-file-name)
                (unless (or (derived-mode-p 'typst-ts-mode)
                            (derived-mode-p 'latex-mode)
                            (derived-mode-p 'tex-mode))
                  (set-auto-mode))
                (when (or (derived-mode-p 'typst-ts-mode)
                          (derived-mode-p 'latex-mode)
                          (derived-mode-p 'tex-mode))
                  (tip-mode 1)
                  ;; Kick off an initial render so overlays appear
                  ;; without the user having to move the cursor.
                  (when (fboundp 'tip-render-all)
                    (run-with-idle-timer 0.3 nil
                                         (lambda (b)
                                           (when (buffer-live-p b)
                                             (with-current-buffer b
                                               (tip-render-all))))
                                         (current-buffer)))))))
        '';

        demoScript = pkgs.writeShellScript "tip-demo" ''
          export PATH=${tip-server}/bin:$PATH
          exec ${demoEmacs}/bin/emacs -Q -l ${demoInit} "$@"
        '';
      in {
        packages = {
          default = tip-server;
          tip-server = tip-server;
          tip-server-static = tip-server-static;
          tip-server-static-aarch64 = tip-server-static-aarch64;
        };

        apps.default = {
          type = "app";
          program = "${tip-server}/bin/tip-server";
        };

        # `nix run .#demo` — spawns a GUI emacs with tip-mode live,
        # typst on the left, latex on the right.
        apps.demo = {
          type = "app";
          program = "${demoScript}";
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
