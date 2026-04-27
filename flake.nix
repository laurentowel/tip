{
  description = "tip-server: Typst + LaTeX preview server for the TIP Emacs mode";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    crane.url = "github:ipetkov/crane";
  };

  outputs = { self, nixpkgs, flake-utils, crane }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
        craneLib = crane.mkLib pkgs;

        # texlive bundle for dev + CI only — distributed binaries
        # rely on the user's existing TeX install (LaTeX backend
        # users already have one).
        testLatexEnv = pkgs.texlive.combine {
          inherit (pkgs.texlive) scheme-full dvisvgm;
        };

        # `perl` is needed by openssl-src at build time (workspace
        # uses openssl's "vendored" feature).
        commonCraneArgs = {
          src = craneLib.cleanCargoSource ./tip-server;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.perl ];
          buildInputs = [ ];
        };

        # Cache dependency compiles separately — typst/comemo etc.
        # don't re-build on changes to our own crates.
        cargoArtifacts = craneLib.buildDepsOnly commonCraneArgs;

        tip-server = craneLib.buildPackage (commonCraneArgs // {
          inherit cargoArtifacts;
          pname = "tip-server";
          version = "0.1.0";
          cargoExtraArgs = "-p tip-server";
          doCheck = false;
          meta = with pkgs.lib; {
            description = "Typst + LaTeX preview server for TIP Emacs mode";
            mainProgram = "tip-server";
            license = licenses.mit;
            platforms = platforms.unix;
          };
        });

        # Musl-static build for GitHub releases.  +crt-static so libc
        # itself is statically linked — the resulting binary runs on
        # any x86_64 Linux without a matching glibc or Nix store.
        staticCrane = crane.mkLib pkgs.pkgsCross.musl64;
        staticCommon = {
          src = staticCrane.cleanCargoSource ./tip-server;
          strictDeps = true;
          nativeBuildInputs = [ pkgs.pkg-config pkgs.perl ];
          RUSTFLAGS = "-C target-feature=+crt-static";
        };
        tip-server-static = staticCrane.buildPackage (staticCommon // {
          cargoArtifacts = staticCrane.buildDepsOnly staticCommon;
          pname = "tip-server-static";
          version = "0.1.0";
          cargoExtraArgs = "-p tip-server";
          doCheck = false;
          meta = tip-server.meta // { description = "tip-server (musl-static)"; };
        });

        # ----- demo + test infrastructure -----

        # typst-ts-mode isn't in melpa snapshots yet — fetch direct.
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
          postUnpack = "";
          meta.description = "Major mode for Typst, tree-sitter based";
        };

        # tree-sitter grammar derivations output `$out/parser` as a .so;
        # treesit-extra-load-path expects `libtree-sitter-LANG.so`.
        mkGrammarDir = lang: pkgs.runCommand "tip-${lang}-grammar-dir" { } ''
          mkdir -p $out
          ln -s ${pkgs.tree-sitter-grammars."tree-sitter-${lang}"}/parser \
                $out/libtree-sitter-${lang}.so
        '';
        typstGrammarDir    = mkGrammarDir "typst";
        markdownGrammarDir = mkGrammarDir "markdown";
        latexGrammarDir    = mkGrammarDir "latex";

        # Pennstander Math — distinctive math font for the demo.
        pennstanderSrc = pkgs.fetchFromGitHub {
          owner = "juliusross1";
          repo = "Pennstander";
          rev = "6dd810d61a41ffd73d7688353ee98fafd1169c24";
          hash = "sha256-qxI41ikKryJriVeQpAt5M1w/p7ojnZbG9yvEDuPs3j4=";
        };

        # Bundled font pool: Pennstander (custom math) + Sarasa Gothic
        # (CJK glyphs, used by the zh showcase).  TipWorld picks this
        # up via TYPST_FONT_PATHS at server startup.
        demoFontDir = pkgs.runCommand "tip-demo-fonts" { } ''
          mkdir -p $out
          cp ${pennstanderSrc}/fonts/otf/PennstanderMath-*.otf $out/
          cp -L ${pkgs.sarasa-gothic}/share/fonts/truetype/*.ttc $out/
        '';

        demoEmacs = (pkgs.emacsPackagesFor pkgs.emacs-pgtk).emacsWithPackages
          (ep: [ typst-ts-mode ep.ef-themes ep.spacious-padding
                 ep.demo-it ep.keycast ep.markdown-mode ]);

        # ----- demo: side-by-side typst/latex with tip-mode live -----
        demoInit = pkgs.writeText "tip-demo-init.el" ''
          (setq inhibit-startup-screen t make-backup-files nil
                auto-save-default nil
                frame-title-format "tip-mode demo (Typst | LaTeX)")
          (when (fboundp 'pixel-scroll-precision-mode)
            (pixel-scroll-precision-mode 1))
          (add-to-list 'treesit-extra-load-path "${typstGrammarDir}/")
          (add-to-list 'load-path "${toString ./lisp}")
          (require 'typst-ts-mode)
          (require 'tip)
          (require 'tip-typst)
          (require 'tip-latex)
          (add-to-list 'auto-mode-alist '("\\.typ\\'" . typst-ts-mode))
          (add-to-list 'auto-mode-alist '("\\.tex\\'" . latex-mode))
          ;; chktex emits false positives on \newcommand bodies; drop
          ;; it so tip-compile-diagnostics is the only flymake source.
          (with-eval-after-load 'tex-mode
            (remove-hook 'flymake-diagnostic-functions #'tex-chktex))
          (add-hook 'latex-mode-hook
                    (lambda ()
                      (remove-hook 'flymake-diagnostic-functions
                                   #'tex-chktex t)))
          (find-file "${./demo/tip-demo.typ}")
          (split-window-right) (other-window 1)
          (find-file "${./demo/tip-demo.tex}")
          (other-window 1)
          (dolist (buf (buffer-list))
            (with-current-buffer buf
              (when (and (buffer-file-name)
                         (or (derived-mode-p 'typst-ts-mode)
                             (derived-mode-p 'latex-mode)
                             (derived-mode-p 'tex-mode)))
                (tip-mode 1)
                (run-with-idle-timer 0.3 nil
                  (lambda (b) (when (buffer-live-p b)
                                (with-current-buffer b (tip-render-all))))
                  (current-buffer)))))
        '';

        demoScript = pkgs.writeShellScript "tip-demo" ''
          export PATH=${tip-server}/bin:$PATH
          export TYPST_FONT_PATHS=${demoFontDir}
          exec ${demoEmacs}/bin/emacs -Q -l ${demoInit} "$@"
        '';

        # Common env for any test/demo that drives the integration
        # daemon — tip-server, emacs+typst-ts-mode, the three grammars.
        testEnvLines = ''
          export PATH=${tip-server}/bin:${demoEmacs}/bin:$PATH
          export TYPST_FONT_PATHS=${demoFontDir}
          export TIP_IT_GRAMMAR_PATH=${typstGrammarDir}
          export TIP_IT_MARKDOWN_GRAMMAR_PATH=${markdownGrammarDir}
          export TIP_IT_LATEX_GRAMMAR_PATH=${latexGrammarDir}
          export TIP_IT_DIR=${./tests/integration}
          export TIP_REPO=${./.}
        '';

        # `nix run .#test` — one umbrella for everything that runs
        # without humans: cargo test + headless ERT + integration
        # specs (--headless).  Exits non-zero on any failure.
        testScript = pkgs.writeShellScript "tip-test" ''
          set -eu
          ${testEnvLines}
          REPO=${./.}
          echo "=== cargo test ==="
          (cd "$REPO/tip-server" && ${pkgs.cargo}/bin/cargo test --workspace)
          echo
          echo "=== headless ERT ==="
          for f in tests/ert/test-tip.el \
                   tests/ert/test-tip-markdown.el \
                   tests/ert/test-tip-latex-treesit.el \
                   tests/ert/test-server.el; do
            echo "--- $f ---"
            (cd "$REPO" && ${demoEmacs}/bin/emacs --batch -l "$f")
          done
          echo
          echo "=== integration specs (headless) ==="
          export TIP_IT_HEADLESS=1
          exec ${pkgs.bash}/bin/bash "$TIP_IT_DIR/run.sh" "$@"
        '';

        # `nix run .#test-interactive` — opens a manual probe.
        # Without args lists what's available; pass a name to launch.
        testInteractiveScript = pkgs.writeShellScript "tip-test-interactive" ''
          set -eu
          ${testEnvLines}
          REPO=${./.}
          MANUAL="$REPO/tests/manual"
          if [ $# -eq 0 ] || [ "$1" = "list" ] || [ "$1" = "--help" ]; then
            echo "Manual / interactive tests:"
            for f in "$MANUAL"/*.el; do
              echo "  $(basename "$f" .el)"
            done
            echo
            echo "Usage: nix run .#test-interactive -- <name>"
            exit 0
          fi
          f="$MANUAL/$1.el"
          if [ ! -f "$f" ]; then
            echo "no such test: $1  (run with no args to list)" >&2
            exit 1
          fi
          shift
          exec ${demoEmacs}/bin/emacs -Q -l "$f" "$@"
        '';

        # `nix run .#showcase` — recorded demo reel using the same
        # daemon infra as `test` but with a curated spec dir + a
        # generous inter-test sleep so a human can watch each scene.
        showcaseScript = pkgs.writeShellScript "tip-showcase" ''
          set -eu
          ${testEnvLines}
          export XDG_DATA_DIRS=${pkgs.sarasa-gothic}/share:${pkgs.fira-math}/share:''${XDG_DATA_DIRS:-/usr/share}
          export TIP_SHOWCASE_DIR=${./showcase}
          export TIP_SHOWCASE_THEME=''${TIP_SHOWCASE_THEME:-modus-operandi}
          exec ${pkgs.bash}/bin/bash "$TIP_SHOWCASE_DIR/run.sh" "$@"
        '';
      in {
        packages = {
          default = tip-server;
          tip-server = tip-server;
          tip-server-static = tip-server-static;
        };

        apps.default = {
          type = "app";
          program = "${tip-server}/bin/tip-server";
        };

        # Two test entry points + demo + showcase.  See
        # tests/README.md for what each runs and how to invoke
        # without nix.
        apps.test = { type = "app"; program = "${testScript}"; };
        apps.test-interactive = {
          type = "app"; program = "${testInteractiveScript}";
        };
        apps.demo = { type = "app"; program = "${demoScript}"; };
        apps.showcase = { type = "app"; program = "${showcaseScript}"; };

        devShells.default = pkgs.mkShell {
          packages = [
            pkgs.cargo pkgs.rustc pkgs.rustfmt pkgs.clippy pkgs.rust-analyzer
            pkgs.emacs-pgtk
            pkgs.pkg-config pkgs.perl
            testLatexEnv
          ];
        };

        # `nix flake check` — pinned reproduction of the test suite.
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
              for f in tests/ert/test-tip.el \
                       tests/ert/test-tip-markdown.el \
                       tests/ert/test-tip-latex-treesit.el; do
                echo "=== $f ==="
                emacs --batch -l "$f"
              done
            '';
            installPhase = "touch $out";
          };
        };
      });
}
