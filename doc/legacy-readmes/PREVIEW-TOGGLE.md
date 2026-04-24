# preview-toggle.el

Generic overlay auto-toggle framework. See `preview-toggle.el` for code.

## Flow

```
Outside math (image shown)
    │ cursor enters
    ▼
pre-command: was-inside = false
    │ point moves
    ▼
post-command: now-inside = true, was = false → OPEN (remove display)
    │
Inside math (source visible, user edits)
    │ cursor leaves
    ▼
pre-command: was-inside = true
    │ point moves
    ▼
post-command: now-inside = false, was = true → CLOSE (recompile)
```

## API

| Variable | Type | Description |
|----------|------|-------------|
| `preview-toggle-type` | symbol | Overlay property name+value |
| `preview-toggle-region-at-point-fn` | `(POS) → (BEG.END)\|nil` | Detect previewable region |
| `preview-toggle-compile-region-fn` | `(BEG END) → void` | Async recompile |

| Function | Description |
|----------|-------------|
| `preview-toggle-mode` | Enable/disable hooks |
| `preview-toggle-open-at-point` | Manually open |
| `preview-toggle-clear-buffer` | Remove all overlays |
