;;; tip-typst.el --- Typst backend for tip (fragment detection + preamble) -*- lexical-binding: t; -*-

;;; Commentary:

;; Typst-specific pieces of TIP:
;;   - tree-sitter math / figure fragment collection
;;   - fragment bounds lookup at point
;;   - Typst preamble (theme color injection)
;;
;; Everything here uses the tree-sitter `typst' grammar and emits Typst
;; source for the server preamble.  A future tip-latex.el will provide
;; the analogous interface for LaTeX.

;;; Code:

(require 'treesit)
(require 'cl-lib)
(require 'tip-backend)

;; Forward declarations — these live in tip.el.  The `defvar' form here
;; just tells the byte-compiler they exist; it doesn't rebind them.
(defvar tip-transparent-bg)
(declare-function tip--color-to-hex "tip" (color))

;;; * customization

(defcustom tip-render-figure nil
  "If non-nil, render `#figure(...)' calls as whole-block previews.
When enabled, the entire figure (body + caption) is treated as a single
fragment; any math inside is swallowed.  Non-math content outside figures
(e.g. bare diagram calls, images) is never rendered — wrap it in a figure
or display math to opt in.  Buffer-local."
  :type 'boolean
  :group 'tip
  :local t)

(defcustom tip-typst-strategy 'auto
  "Compile strategy for the Typst backend.
- `auto' (default): bottom-up.  Per-fragment synthetic compile,
  immune to most leaf-extraction quirks (cross-references,
  `#outline()' re-rendering, header/footer bleed).  Top-down's
  amortized-compile speed-up doesn't justify the bleed risk for
  most documents, so auto picks the safer path.
- `bottom-up': same as auto today.  Explicit opt-in.
- `top-down': compile the whole document once, extract per-fragment
  SVGs from the frame tree.  Faster for batch renders on long docs
  and reflects document-level context (heading font size,
  surrounding face).  Switch on with `M-x tip-typst-top-down'.

The two interactive commands `tip-typst-top-down' and
`tip-typst-bottom-up' set this buffer-locally and re-render."
  :type '(choice (const :tag "Auto (currently bottom-up)" auto)
                 (const :tag "Bottom-up (per-fragment synthetic doc)" bottom-up)
                 (const :tag "Top-down (single doc compile + extract)" top-down))
  :safe (lambda (v) (memq v '(auto bottom-up top-down)))
  :group 'tip
  :local t)

;;; * tree-sitter helpers

(defun tip--figure-node-p (node)
  "Return non-nil if NODE is a `figure' function call."
  (when-let* ((node)
              (ntype (treesit-node-type node))
              ((equal "call" (if (symbolp ntype) (symbol-name ntype) ntype)))
              (first-child (treesit-node-child node 0))
              (name (treesit-node-text first-child t)))
    (equal name "figure")))

(defun tip-typst--heading-face-at (pos)
  "Return `typst-ts-markup-header-face-N' if POS is inside a Typst heading.
Walks the tree-sitter `typst' parser ancestors looking for a `heading'
node.  Level is the count of `=' chars at the heading's start.  Returns
nil when not in a heading or the parser isn't ready.

Why this exists: typst-ts-mode's font-lock query (typst-ts-mode.el:80)
fontifies only the heading's `(text)' children, leaving math fragments
inside a heading without the header face.  `tip--resolve-image-face'
then sees a plain face on chars adjacent to `$…$' and the image's `em'
resolves against the default font — math stays small even on a `=='
heading where surrounding text is rendered at 1.7×.  This helper
short-circuits that gap by inspecting the parse tree directly."
  (when (and (fboundp 'treesit-available-p)
             (treesit-available-p)
             (fboundp 'treesit-ready-p)
             (treesit-ready-p 'typst t))
    (let* ((node (treesit-node-at pos 'typst))
           (h node))
      (while (and h (not (equal "heading" (treesit-node-type h))))
        (setq h (treesit-node-parent h)))
      (when h
        ;; Heading text starts with N `=' followed by space.  Read the
        ;; first 6 chars of the heading and count leading `=' — robust
        ;; to indentation since the heading node starts at the first `='.
        (let* ((start (treesit-node-start h))
               (end (min (+ start 6) (point-max)))
               (text (buffer-substring-no-properties start end))
               (level (or (and (string-match "\\`=+" text)
                               (length (match-string 0 text)))
                          1))
               (level (max 1 (min 6 level))))
          (intern (format "typst-ts-markup-header-face-%d" level)))))))

(defun tip-typst--surrounding-extra-face (frag-beg _frag-end)
  "Return a Typst-specific face to layer onto the resolved image face.
Currently: header face for math sitting inside a heading.  Returns
nil otherwise.  See `tip-typst--heading-face-at' for the why."
  (tip-typst--heading-face-at frag-beg))

(defun tip--inside-let-binding-p (node)
  "Return non-nil if NODE is inside a `#let' binding (definition, not invocation)."
  (let ((parent (treesit-node-parent node)))
    (while (and parent
                (not (equal "let" (treesit-node-type parent))))
      (setq parent (treesit-node-parent parent)))
    (not (null parent))))

(defun tip--collect-figure-ranges (node beg end avoid-pos)
  "Recursively find `#figure(...)' calls under NODE.
Skips calls inside #let bindings (function definitions, not invocations).
Does not descend into a matched figure, so nested figures are not emitted.
Returns a list of (BEG . END) ranges."
  (let ((node-start (treesit-node-start node))
        (node-end (treesit-node-end node))
        (result nil))
    (when (and (<= node-start end) (>= node-end beg))
      (if (and (tip--figure-node-p node)
               (not (tip--inside-let-binding-p node)))
          (let ((start (max beg (1- node-start)))
                (fend (min end node-end)))
            (when (or (null avoid-pos)
                      (not (and (>= avoid-pos start) (<= avoid-pos fend))))
              (push (cons start fend) result)))
        (dotimes (i (treesit-node-child-count node))
          (setq result (nconc result
                              (tip--collect-figure-ranges
                               (treesit-node-child node i) beg end avoid-pos))))))
    result))

;;; * fragment location API

(defun tip-collect-fragment-locations (beg end &optional avoid-pos)
  "Collect math (and figure) fragment byte positions in region BEG..END.
Returns a list of alists with start/end keys.
Skips fragment containing AVOID-POS if given.
Filters out nested ranges — only keeps outermost fragments.
When `tip-render-figure' is non-nil, top-level `#figure(...)' calls are
also included (and any math inside them is filtered as nested)."
  (let (ranges fragments)
    ;; Collect math ranges (skip empty, skip inside #let bindings)
    (dolist (pair (treesit-query-range 'typst "((math) @math)"))
      (when (and
             (>= (car pair) beg)
             (<= (cdr pair) end)
             (> (- (cdr pair) (car pair)) 2) ;; skip $$ (length 2)
             (not (string-blank-p
                   (buffer-substring-no-properties
                    (1+ (car pair)) (1- (cdr pair))))) ;; skip $ $
             (not (tip--inside-let-binding-p
                   (treesit-node-at (car pair) 'typst)))
             (or (null avoid-pos)
                 (not (and (>= avoid-pos (car pair))
                           (<= avoid-pos (cdr pair))))))
        (push pair ranges)))
    ;; Collect figure ranges when enabled
    (when tip-render-figure
      (let ((root (treesit-buffer-root-node 'typst)))
        (when root
          (setq ranges (nconc ranges
                              (tip--collect-figure-ranges root beg end avoid-pos))))))
    ;; Filter nested ranges
    (setq ranges (nreverse ranges))
    (let (outer)
      (dolist (r ranges)
        (unless (cl-some (lambda (o)
                           (and (not (equal o r))
                                (<= (car o) (car r))
                                (>= (cdr o) (cdr r))))
                         ranges)
          (push r outer)))
      (dolist (pair (nreverse outer))
        (push `(("start" . ,(1- (position-bytes (car pair))))
                ("end" . ,(1- (position-bytes (cdr pair)))))
              fragments)))
    (nreverse fragments)))

;;; * bounds at point

(defun tip--get-bounds-of-math-at-point (x)
  "Return (BEG . END) of math (or figure, when enabled) fragment at X.
Uses local tree-sitter node walk — O(depth) not O(buffer).
Half-open interval: returns bounds only if BEG <= X < END."
  (let ((node (treesit-node-at x 'typst)))
    (or
     ;; When figure rendering is on, prefer the enclosing figure call so that
     ;; positions inside inner math resolve to the fragment actually rendered.
     (when tip-render-figure
       (let ((n node) (found nil))
         (while (and n (not found))
           (if (tip--figure-node-p n)
               (setq found n)
             (setq n (treesit-node-parent n))))
         (when (and (not found) (< x (point-max)) (eq (char-after x) ?#))
           (setq n (treesit-node-at (1+ x) 'typst))
           (while (and n (not found))
             (if (tip--figure-node-p n)
                 (setq found n)
               (setq n (treesit-node-parent n)))))
         (when (and found (not (tip--inside-let-binding-p found)))
           (let ((beg (1- (treesit-node-start found)))
                 (end (treesit-node-end found)))
             (when (and (<= beg x) (< x end))
               (cons beg end))))))
     ;; Check if we're inside a math node (walk up).
     (let ((n node))
       (while (and n (not (equal "math" (treesit-node-type n))))
         (setq n (treesit-node-parent n)))
       (when (and n
                  (<= (treesit-node-start n) x)
                  (< x (treesit-node-end n))
                  (not (tip--inside-let-binding-p n)))
         (cons (treesit-node-start n) (treesit-node-end n)))))))

;;; * preamble (theme sync)

(defun tip--build-preamble ()
  "Build a Typst preamble that syncs Emacs theme colors.
Text size override is sent separately via page_setup (after skeleton)
so it takes precedence over document-level #set text rules."
  (let ((fg (tip--color-to-hex (face-attribute 'default :foreground))))
    (concat
     (format "#show math.equation: set text(rgb(\"%s\"))\n" fg)
     (unless tip-transparent-bg
       (format "#set page(fill: rgb(\"%s\"))\n"
               (tip--color-to-hex (face-attribute 'default :background)))))))

;;; * fragment classification

(defun tip-typst-classify-fragment (text)
  "Classify Typst fragment TEXT for display purposes.
Returns one of:
  `block'          — starts with `#' (e.g. `#figure(...)').
  `display-single' — single-line display math (`$ ... $' no newline).
  `display-multi'  — multi-line display math.
  `inline'         — otherwise (`$...$')."
  (cond
   ((or (zerop (length text)) (eq (aref text 0) ?#))
    (if (zerop (length text)) 'inline 'block))
   ((and (>= (length text) 3)
         (eq (aref text 0) ?$)
         (memq (aref text 1) '(?\s ?\t))
         (not (string-match-p "\n" (substring text 1 -1))))
    'display-single)
   ((and (>= (length text) 2)
         (string-match-p "\n" (substring text 1 -1)))
    'display-multi)
   (t 'inline)))

;;; * skeleton view

(declare-function tip--show-debug-skeleton "tip")

(defun tip-typst-show-skeleton ()
  "Show the scoped skeleton for the Typst fragment at point.
Typst scope varies by position, so a fragment under point is required."
  (let ((bounds (tip-bounds-at-point (point))))
    (unless bounds
      (user-error
       "Typst skeleton requires point inside a math/figure fragment"))
    (tip--show-debug-skeleton
     (1- (position-bytes (car bounds)))
     (1- (position-bytes (cdr bounds)))
     "*tip-skeleton*"
     (and (fboundp 'typst-ts-mode) #'typst-ts-mode))))

;;; * strategy resolution + sticky toggles

(defun tip-typst-resolve-strategy (_n-fragments)
  "Return the protocol strategy string for an upcoming compile.
Reads `tip-typst-strategy'.  `auto' resolves to bottom-up — top-down
has structural failure modes (leaf bleed from `#outline()' / headers
/ cross-refs) that aren't worth the per-batch speed-up for typical
documents.  Users who want top-down call `M-x tip-typst-top-down' or
set `tip-typst-strategy' explicitly."
  (pcase tip-typst-strategy
    ('top-down "top-down")
    (_         "bottom-up")))

(declare-function tip-render-all "tip-render")

(defun tip-typst--rerender-buffer ()
  "Re-render the current buffer, if `tip-render-all' is available."
  (when (fboundp 'tip-render-all)
    (call-interactively 'tip-render-all)))

;;;###autoload
(defun tip-typst-top-down ()
  "Force this buffer to use the top-down strategy and re-render.
Sets `tip-typst-strategy' buffer-locally; survives until you
either call `tip-typst-bottom-up' or reset the variable."
  (interactive)
  (setq-local tip-typst-strategy 'top-down)
  (message "tip-typst-strategy → top-down (buffer-local)")
  (tip-typst--rerender-buffer))

;;;###autoload
(defun tip-typst-bottom-up ()
  "Force this buffer to use the bottom-up strategy and re-render.
Sets `tip-typst-strategy' buffer-locally."
  (interactive)
  (setq-local tip-typst-strategy 'bottom-up)
  (message "tip-typst-strategy → bottom-up (buffer-local)")
  (tip-typst--rerender-buffer))

;;;###autoload
(defun tip-typst-auto ()
  "Restore auto strategy selection in this buffer."
  (interactive)
  (kill-local-variable 'tip-typst-strategy)
  (message "tip-typst-strategy → auto (buffer default)")
  (tip-typst--rerender-buffer))

;;; * backend registration

(defvar tip-server-executable)

(tip-register-backend
 (make-tip-backend
  :name 'typst
  :major-modes '(typst-ts-mode typst-mode)
  :collect-fragments-fn #'tip-collect-fragment-locations
  :bounds-at-point-fn #'tip--get-bounds-of-math-at-point
  :build-preamble-fn #'tip--build-preamble
  :classify-fragment-fn #'tip-typst-classify-fragment
  :server-executable "tip-server"
  :show-skeleton-fn #'tip-typst-show-skeleton))

(provide 'tip-typst)

;;; tip-typst.el ends here
