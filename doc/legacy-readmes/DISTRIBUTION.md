# TIP Distribution Plan

## Repository Structure for Distribution

The Rust server becomes a subdirectory of the Emacs package (like pdf-tools' `server/`):

```
tip/                          ← top-level = Emacs package
├── tip.el                    # Main package
├── preview-toggle.el         # Generic overlay framework
├── tip-server/               # Rust server (subdirectory)
│   ├── Cargo.toml
│   ├── crates/
│   │   ├── tip-protocol/
│   │   ├── tip-core/
│   │   └── tip-server/
│   ├── testkit/
│   └── Dockerfile
├── Makefile                  # Build entry point
├── test-tip.el               # ERT tests
└── tests/                    # Integration tests
```

## Three Installation Paths

### Path 1: Pre-built Binary (lowest friction, like xeft)

Host pre-built binaries on GitHub Releases for common platforms:
- `tip-server-x86_64-linux`
- `tip-server-aarch64-linux`
- `tip-server-x86_64-darwin`
- `tip-server-aarch64-darwin`

In `tip.el`:
```elisp
(defcustom tip-server-executable nil
  "Path to tip-server binary. Auto-detected if nil."
  :type '(choice (const nil) string)
  :group 'tip)

(defvar tip--prebuilt-urls
  '(("x86_64-linux" . "https://github.com/.../releases/latest/download/tip-server-x86_64-linux")
    ("aarch64-linux" . "https://github.com/.../releases/latest/download/tip-server-aarch64-linux")
    ("x86_64-darwin" . "https://github.com/.../releases/latest/download/tip-server-x86_64-darwin")
    ("aarch64-darwin" . "https://github.com/.../releases/latest/download/tip-server-aarch64-darwin")))

(defun tip--detect-platform ()
  "Return platform key for pre-built binary."
  (let ((arch (car (split-string system-configuration "-")))
        (os (cond ((eq system-type 'gnu/linux) "linux")
                  ((eq system-type 'darwin) "darwin")
                  (t nil))))
    (when os (format "%s-%s" arch os))))

(defun tip--find-server ()
  "Find or prompt to install tip-server."
  (or tip-server-executable
      (executable-find "tip-server")
      ;; Check beside tip.el
      (let ((local (expand-file-name "tip-server/target/release/tip-server"
                                      (file-name-directory (locate-library "tip")))))
        (when (file-executable-p local) local))
      ;; Prompt user
      (tip--prompt-install)))

(defun tip--prompt-install ()
  "Prompt user to install tip-server."
  (let ((choice (read-char-choice
                 (concat "tip-server not found. Install:\n"
                         "  [d] Download pre-built binary\n"
                         "  [c] Compile from source (needs Rust)\n"
                         "  [k] Use Docker\n"
                         "  [q] Cancel\n")
                 '(?d ?c ?k ?q))))
    (pcase choice
      (?d (tip--download-prebuilt))
      (?c (tip--compile-from-source))
      (?k (tip--setup-docker))
      (?q (user-error "tip-server required for tip-mode")))))
```

### Path 2: Compile from Source (like vterm)

Requires: Rust toolchain (`cargo`).

`Makefile` at package root:
```makefile
.PHONY: server clean test

CARGO ?= cargo
PROFILE ?= release

server:
	cd tip-server && $(CARGO) build --$(PROFILE)
	@echo "Built: tip-server/target/$(PROFILE)/tip-server"

clean:
	cd tip-server && $(CARGO) clean

test:
	cd tip-server && $(CARGO) test
	emacs --batch -l test-tip.el
```

In `tip.el`:
```elisp
(defun tip--compile-from-source ()
  "Compile tip-server from source."
  (unless (executable-find "cargo")
    (user-error "Rust toolchain not found. Install from https://rustup.rs"))
  (let* ((pkg-dir (file-name-directory (locate-library "tip")))
         (default-directory pkg-dir)
         (buf (get-buffer-create "*tip-server-build*")))
    (message "Compiling tip-server (this takes ~2 min on first build)...")
    (with-current-buffer buf (erase-buffer))
    (let ((proc (start-process "tip-build" buf "make" "server")))
      (set-process-sentinel
       proc
       (lambda (_proc event)
         (if (string-match-p "finished" event)
             (progn
               (setq tip-server-executable
                     (expand-file-name "tip-server/target/release/tip-server" pkg-dir))
               (message "tip-server compiled successfully!"))
           (pop-to-buffer buf)
           (error "tip-server build failed. See *tip-server-build* buffer")))))))
```

### Path 3: Docker (zero local deps)

`tip-server/Dockerfile`:
```dockerfile
FROM rust:1.89-slim AS builder
WORKDIR /app
COPY . .
RUN cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y fontconfig && rm -rf /var/lib/apt/lists/*
COPY --from=builder /app/target/release/tip-server /usr/local/bin/
ENTRYPOINT ["tip-server"]
```

In `tip.el`, Docker mode wraps the server in a container:
```elisp
(defcustom tip-use-docker nil
  "If non-nil, run tip-server via Docker."
  :type 'boolean
  :group 'tip)

(defcustom tip-docker-image "tip-server:latest"
  "Docker image for tip-server."
  :type 'string
  :group 'tip)

(defun tip--start-docker-server ()
  "Start tip-server in a Docker container with stdio."
  (make-process
   :name "tip-server"
   :command (list "docker" "run" "--rm" "-i"
                  ;; Mount project for import resolution
                  "-v" (concat (file-name-directory (buffer-file-name)) ":/project")
                  ;; Mount local packages
                  "-v" (concat (expand-file-name "~/.local/share/typst/packages") ":/root/.local/share/typst/packages:ro")
                  tip-docker-image)
   :connection-type 'pipe
   :filter #'tip--process-filter
   :sentinel #'tip--process-sentinel
   :noquery t))
```

## MELPA Recipe

```elisp
;; melpa/recipes/tip
(tip :fetcher github
     :repo "user/tip"
     :files ("tip.el"
             "preview-toggle.el"
             "Makefile"
             "tip-server/Cargo.toml"
             "tip-server/Cargo.lock"
             "tip-server/crates"
             "tip-server/testkit"))
```

## GitHub CI for Pre-built Binaries

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ['v*']
jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
            name: tip-server-x86_64-linux
          - os: ubuntu-latest
            target: aarch64-unknown-linux-gnu
            name: tip-server-aarch64-linux
          - os: macos-latest
            target: x86_64-apple-darwin
            name: tip-server-x86_64-darwin
          - os: macos-latest
            target: aarch64-apple-darwin
            name: tip-server-aarch64-darwin
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - run: cd tip-server && cargo build --release --target ${{ matrix.target }}
      - uses: softprops/action-gh-release@v1
        with:
          files: tip-server/target/${{ matrix.target }}/release/tip-server
```

## Migration Plan

1. Restructure: move `tip/` contents to repo root, `tip-server/` stays as subdirectory
2. Add `Makefile`, `Dockerfile`, `.github/workflows/release.yml`
3. Implement `tip--find-server` + `tip--prompt-install` in tip.el
4. Test all three paths (pre-built, compile, docker)
5. Submit to MELPA
