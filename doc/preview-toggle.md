# preview-toggle.el: Auto-Toggling Inline Overlays

## What It Does

When you move your cursor into a rendered math fragment, the SVG disappears and the source text is revealed. When you move out, the source is recompiled and the SVG reappears. This happens automatically on every cursor movement, with no explicit commands.

```
Cursor outside:   Text ⟨SVG of a+b⟩ more text     ← you see the rendered math
Cursor inside:    Text $a + b$ more text             ← you see the source
Cursor leaves:    Text ⟨SVG of a+b⟩ more text     ← recompiled, SVG is back
```

This is the core interaction pattern of TIP, and it's implemented as a **generic, reusable framework** in `preview-toggle.el` — completely independent of Typst, math, or SVG. It only knows about overlays and cursor transitions.

## Why It's Separate

preview-toggle.el has no dependencies on tip.el, typst-ts-mode, or any Typst-specific code. It's configured via three buffer-local variables:

```elisp
preview-toggle-type              ; symbol identifying overlays (e.g. 'tip)
preview-toggle-region-at-point-fn ; function: position → (BEG . END) or nil
preview-toggle-compile-region-fn  ; function: (BEG END) → creates overlay async
```

TIP sets these in `tip-mode`:

```elisp
(setq-local preview-toggle-type 'tip)
(setq-local preview-toggle-region-at-point-fn #'tip--get-bounds-of-math-at-point)
(setq-local preview-toggle-compile-region-fn #'tip--compile-region)
```

A future LaTeX inline preview system could reuse the same framework:

```elisp
(setq-local preview-toggle-type 'latex-preview)
(setq-local preview-toggle-region-at-point-fn #'latex--get-bounds-at-point)
(setq-local preview-toggle-compile-region-fn #'latex--compile-region)
```

Same auto-toggle behavior, different detection and compilation backends.

## The State Machine

The framework tracks one piece of state: **was the cursor inside a previewable region before the current command?**

Every command triggers two hooks:

1. **`pre-command-hook`**: Record whether cursor is currently inside (`was-inside`), save position to a marker.
2. **`post-command-hook`**: Check if cursor is now inside (`now-inside`). Compare with `was-inside`.

Four transitions are possible:

```
was-inside  now-inside  Action
─────────── ─────────── ────────────────────────────────
nil         nil         Nothing (cursor stayed outside)
nil         t           OPEN: reveal source at point
t           nil         CLOSE: recompile at marker, show SVG
t           t           Check if SAME overlay:
                          same → nothing (editing inside)
                          diff → CLOSE old + OPEN new (jumped between fragments)
```

### Open

```elisp
(defun preview-toggle-open-at-point ()
  (let ((ov (preview-toggle--overlay-at (point))))
    (when ov
      (overlay-put ov 'display nil)   ; remove SVG image
      (overlay-put ov 'face nil))))   ; remove error highlight
```

Setting `display` to nil makes the overlay transparent — the underlying buffer text shows through. The overlay itself stays in place (it still has the `tip` property) so it can be found later.

### Close

```elisp
(defun preview-toggle--close-at-marker ()
  (when-let* ((pos (marker-position preview-toggle--marker))
              (bounds (funcall region-fn pos))     ; ask TIP for fragment bounds
              (compile-fn preview-toggle-compile-region-fn))
    ;; Delete the old overlay
    (dolist (ov (overlays-in (car bounds) (cdr bounds)))
      (when (eq (overlay-get ov preview-toggle-type) preview-toggle-type)
        (delete-overlay ov)))
    ;; Recompile → new overlay with fresh SVG
    (funcall compile-fn (car bounds) (cdr bounds))))
```

Critical detail: close uses the **marker position** (where the cursor was before the command), not the current point. The cursor has already left the fragment — we need to find the fragment's bounds at the OLD position.

The compile function is async — it sends a request to the server and creates the overlay when the response arrives. There's a brief moment where neither the SVG nor the source text is visible (the old overlay is deleted, the new one hasn't arrived yet). In practice this is <5ms and imperceptible.

## Inside Detection: Two Layers

"Is the cursor inside a previewable region?" has two answers:

```elisp
(defun preview-toggle--inside-p ()
  (or (preview-toggle--overlay-at (point))           ; 1. overlay exists here
      (funcall preview-toggle-region-at-point-fn (point)))) ; 2. region detected here
```

**Layer 1: Overlay check.** Fast — `overlays-at` is O(overlays at point). If there's a `tip` overlay at point, we're inside. This handles the common case: cursor enters a rendered fragment.

**Layer 2: Region function.** Called when no overlay exists at point. This handles the case where the cursor is inside a math fragment that hasn't been rendered yet (no overlay). TIP's `tip--get-bounds-of-math-at-point` walks the tree-sitter AST to find `$...$` at point. This is O(tree depth) — see `doc/baseline-alignment.md` for why it was changed from O(buffer).

Why both layers? Consider: you type `$a + b$` and the cursor is inside. There's no overlay yet (the fragment was just typed, never compiled). Layer 1 returns nil. Layer 2 finds the math region via tree-sitter and returns `(BEG . END)`. The pre-command hook records `was-inside = t`. When you leave, the close transition fires and compiles the fragment for the first time.

## Overlay Detection Subtleties

### Half-open intervals

Emacs overlays use half-open intervals: an overlay `[BEG, END)` covers positions BEG through END-1. `overlays-at END` does NOT find the overlay. This matters at fragment boundaries.

The fix: check both `overlays-at pos` and `overlays-in pos (1+ pos)`:

```elisp
(or (seq-find pred (overlays-at pos))
    (seq-find pred (overlays-in pos (min (1+ pos) (point-max)))))
```

### The boundary position problem

When the cursor is at the closing `$` of `$a + b$` (position = end of fragment), is it inside or outside?

**Inside** from the tree-sitter perspective: the `$` node is a child of the math node.
**Outside** from the overlay perspective: `overlays-at END` doesn't find the overlay.

TIP's bounds function uses strict half-open: `start <= x < end`. Position at `end` returns nil (outside). This matches the overlay behavior and prevents the close transition from failing when the cursor exits via the closing delimiter.

This was a real bug: `treesit-node-at` at position `end` returns the closing `$` node, whose parent IS the math node. Without the explicit `< x end` check, the position was incorrectly reported as inside, preventing overlays from closing. Especially visible with adjacent short fragments like `$a$ $b$`.

### The `#` prefix problem (diagrams)

For diagram fragments like `#cetz.canvas(...)`, the overlay starts at the `#` character (one before the tree-sitter `call` node). But tree-sitter puts `#` as a sibling of `call`, not a child. So `treesit-node-at` at the `#` position walks up to `markup`, never reaching `call`.

The fix: if the tree walk fails and `char-after` is `#`, retry at position+1 to find the sibling `call` node.

## Commands That Don't Toggle

Some commands shouldn't trigger open/close — scrolling, for instance. Moving the view without moving point shouldn't toggle overlays.

```elisp
(defvar preview-toggle-ignored-commands
  '(pixel-scroll-precision scroll-up-command scroll-down-command))
```

Both hooks check `(memq this-command preview-toggle-ignored-commands)` and bail out early if matched.

## Fragment-to-Fragment Jumps

When the cursor jumps directly from one fragment to another (e.g., via search or avy), the third transition case handles it:

```elisp
((and now-inside preview-toggle--was-inside
      (not (eq (preview-toggle--overlay-at (point))
               (preview-toggle--overlay-at (marker-position preview-toggle--marker)))))
 (preview-toggle--close-at-marker)   ; close the OLD fragment
 (preview-toggle-open-at-point))     ; open the NEW fragment
```

It checks whether the overlay at the current point is the SAME object as the overlay at the marker (old position). If different: close old, open new. If same: the cursor moved within the same fragment, do nothing.

## What It Doesn't Do

preview-toggle.el deliberately avoids:

- **Compilation logic**: It calls `compile-region-fn` but doesn't know what compilation means.
- **Fragment detection**: It calls `region-at-point-fn` but doesn't know about tree-sitter or math.
- **Overlay creation**: The compile function creates overlays asynchronously. preview-toggle only deletes them (on close) and modifies their `display` property (on open).
- **Timer-based behavior**: No idle timers, no polling. Every action is a direct response to a cursor movement command. This is the no-DWIM principle.
- **Error handling**: If a fragment fails to compile, the compile function handles it (error face overlay). preview-toggle doesn't know about errors.

## Performance

The hooks run on EVERY command — every keystroke, every cursor movement. They must be fast.

- `pre-command-hook`: One `preview-toggle--inside-p` call + marker set. The inside-p check is O(overlays at point) + potentially O(tree depth) for the region function. In practice: <0.1ms.
- `post-command-hook`: Same inside-p check + transition logic. On "nothing changed" (the common case): two comparisons and an early return.

The expensive case is `close`: it deletes an overlay and triggers async compilation. But this only happens when the cursor leaves a fragment — maybe a few times per minute during normal editing.

The O(tree depth) region function replaced the original O(buffer) tree-sitter query. The original queried ALL math nodes in the buffer on every keystroke. For a 1000-fragment document, this caused visible input lag. The tree walk fixes it.

## The Reusability Promise

preview-toggle.el is 125 lines. It handles:
- Cursor transition detection (4 cases)
- Overlay open/close
- Marker-based position tracking
- Command filtering
- Minor mode lifecycle

Any inline preview system that shows images in a buffer and wants auto-toggle can use it. The only contract: overlays must have a type property (`overlay-put ov TYPE TYPE`), and the caller provides detection and compilation functions.

## Files

| File | Role |
|------|------|
| `preview-toggle.el` | The framework (125 lines) |
| `tip.el` | Configures it: sets type, region-fn, compile-fn |
| `tip.el:tip--get-bounds-of-math-at-point` | The region-at-point function |
| `tip.el:tip--compile-region` | The compile function |
| `doc/baseline-alignment.md` | Why O(tree depth) matters for the region function |
