;;; tip-log.el --- Centralized logging hub for tip -*- lexical-binding: t; -*-

;;; Commentary:

;; Single funnel for tip's diagnostic traffic: server lifecycle,
;; protocol traffic, render warnings, internal traces.  Replaces the
;; previous mix of `tip-enable-debug', `tip-verbose', `tip-echo-errors',
;; and ~40 scattered raw `message' calls.
;;
;; Math compile errors keep their structured pipe (overlays + flymake
;; via tip-errors.el) — `tip-log' is for the *meta*: the kind of
;; information you'd grep through if "the server crashed" or "my
;; preview suddenly went stale."
;;
;; Public API:
;;
;;   (tip-log LEVEL CATEGORY FORMAT &rest ARGS)
;;     Record a log entry.  LEVEL is `debug', `info', `warning', or
;;     `error'.  CATEGORY is a freeform symbol naming a subsystem.
;;
;;   (tip-log-protocol DIRECTION METHOD ID PARAMS)
;;     Specialized helper that scrubs request/response payloads
;;     before logging.  See `tip-log-protocol-scrub-fields' for the
;;     fields that get replaced with size markers.
;;
;;   M-x tip-show-log         pop the *tip-log* buffer
;;   M-x tip-clear-log        drop all entries
;;
;; UI: *tip-log* uses `tabulated-list-mode' — sortable columns
;; (time / level / category), filtering by level (`L') and category
;; (`C'), refresh (`g'), clear (`k'), and `RET' on a row to view full
;; detail in a separate buffer (useful for protocol payloads truncated
;; in the table view).
;;
;; Inspired by `*Elpaca-Log*' and `ibuffer'.

;;; Code:

(require 'cl-lib)
(require 'tabulated-list)

;;; * customization

(defgroup tip-log nil
  "Logging hub for tip."
  :group 'tip)

(defcustom tip-log-min-level 'info
  "Minimum severity recorded.  Entries below this level are dropped
at the source — changing this at runtime won't surface earlier
entries, but it also means the log doesn't pay for them."
  :type '(choice (const :tag "Debug (very chatty)" debug)
                 (const :tag "Info"                 info)
                 (const :tag "Warning"              warning)
                 (const :tag "Error only"           error))
  :group 'tip-log)

(defcustom tip-log-echo-level 'info
  "Minimum severity also mirrored to the echo area / *Messages*.
Set to `error' to keep the echo area quiet during normal operation."
  :type '(choice (const :tag "Echo everything"          debug)
                 (const :tag "Info and above (default)" info)
                 (const :tag "Warning and above"        warning)
                 (const :tag "Error only"               error))
  :group 'tip-log)

(defcustom tip-log-ring-size 2000
  "Maximum number of entries kept in memory.  Oldest entries are
evicted when the limit is hit.  At ~200 bytes/entry this caps memory
at roughly 400 KB."
  :type 'integer
  :group 'tip-log)

(defcustom tip-log-protocol-scrub-fields
  '(content svg data preamble page_setup)
  "Field names whose values are replaced with `<NB>' size markers
in protocol logs.  These are the fields that can carry KB-to-MB
payloads; logging them verbatim makes the log buffer huge and
slow."
  :type '(repeat symbol)
  :group 'tip-log)

(defcustom tip-log-protocol-truncate 80
  "Maximum length of any single string value in a scrubbed protocol log.
Longer strings are truncated with an `…' marker.  Applies to fields
NOT in `tip-log-protocol-scrub-fields' (those get replaced with size
markers regardless of length)."
  :type 'integer
  :group 'tip-log)

;;; * faces

(defface tip-log-debug-face
  '((t :inherit shadow))
  "Face for debug-level log entries.")

(defface tip-log-info-face
  '((t :inherit default))
  "Face for info-level log entries.")

(defface tip-log-warning-face
  '((t :inherit warning))
  "Face for warning-level log entries.")

(defface tip-log-error-face
  '((t :inherit error))
  "Face for error-level log entries.")

;;; * level helpers

(defconst tip-log--level-rank
  '((debug . 0) (info . 1) (warning . 2) (error . 3))
  "Numeric rank of each severity, for `>=' comparisons.")

(defun tip-log--rank (level)
  "Numeric rank of LEVEL.  Unknown levels rank at +∞ (always pass)."
  (or (alist-get level tip-log--level-rank) 99))

(defun tip-log--passes-p (level threshold)
  "Non-nil when LEVEL is at least as severe as THRESHOLD."
  (>= (tip-log--rank level) (tip-log--rank threshold)))

(defun tip-log--face-for (level)
  (pcase level
    ('debug   'tip-log-debug-face)
    ('info    'tip-log-info-face)
    ('warning 'tip-log-warning-face)
    ('error   'tip-log-error-face)
    (_        'default)))

;;; * the ring

(cl-defstruct tip-log-entry
  time      ; float, `float-time'
  level     ; symbol
  category  ; symbol
  message   ; string (one line)
  detail    ; string or nil — multi-line context shown in detail buffer
  file      ; string or nil — associated file (buffer-file-name at log-time)
  backend)  ; symbol or nil — `typst', `latex', `katex', or nil

(defun tip-log--current-file ()
  "Best-effort file path for the entry being logged.
Returns `buffer-file-name' if any, else falls through to
`tip--current-uri' (which yields \"\" for unsaved buffers — we
collapse that to nil)."
  (or buffer-file-name
      (and (fboundp 'tip--current-uri)
           (let ((u (tip--current-uri)))
             (and (stringp u) (not (string-empty-p u)) u)))))

(defun tip-log--current-backend ()
  "Best-effort backend id for the entry being logged.  Returns a
symbol — `tip--current-backend-id' returns a string for the wire
protocol, but tip-log uses symbols throughout (filter dispatch,
`symbol-name' in the table view), so we coerce here."
  (when (fboundp 'tip--current-backend-id)
    (let ((id (tip--current-backend-id)))
      (cond
       ((symbolp id) id)
       ((stringp id) (intern id))
       (t nil)))))

(defvar tip-log--entries nil
  "All log entries, newest LAST.  A list (not a true ring) trimmed
on each insert.  Lists are fast enough at 2000 entries.")

(defun tip-log--ensure-buffer ()
  "Return the *tip-log* buffer, creating + initializing it if absent.
Called on the first entry so `C-x b *tip-log*' works without first
running `tip-show-log'."
  (let* ((name "*tip-log*")
         (existing (get-buffer name)))
    (or existing
        (let ((buf (get-buffer-create name)))
          (with-current-buffer buf
            (tip-log-mode))
          buf))))

(defun tip-log--push (entry)
  "Append ENTRY, trim to `tip-log-ring-size', refresh any open view.
Also materializes *tip-log* on first call so the user can `C-x b' to
it before invoking `tip-show-log'."
  (setq tip-log--entries
        (let ((all (nconc tip-log--entries (list entry))))
          (let ((excess (- (length all) tip-log-ring-size)))
            (if (> excess 0) (nthcdr excess all) all))))
  (tip-log--ensure-buffer)
  (tip-log--refresh-buffer-if-visible))

;;; * core API

;;;###autoload
(defun tip-log (level category fmt &rest args)
  "Record a log entry at LEVEL in CATEGORY with formatted message.
LEVEL is `debug', `info', `warning', or `error'.  CATEGORY is a
symbol naming the subsystem (e.g. `server', `protocol', `compile').
FMT and ARGS are passed to `format'.

Entries below `tip-log-min-level' are dropped — no string formatting
cost.  Entries at or above `tip-log-echo-level' are also mirrored to
the echo area; `error' additionally raises `display-warning'."
  (when (tip-log--passes-p level tip-log-min-level)
    (let* ((msg (apply #'format fmt args))
           (entry (make-tip-log-entry
                   :time (float-time)
                   :level level
                   :category category
                   :message msg
                   :detail nil
                   :file (tip-log--current-file)
                   :backend (tip-log--current-backend))))
      (tip-log--push entry)
      (when (tip-log--passes-p level tip-log-echo-level)
        (tip-log--echo level category msg))
      (when (eq level 'error)
        (display-warning 'tip msg :warning)))))

;;;###autoload
(defun tip-log-with-detail (level category fmt detail &rest args)
  "Like `tip-log', but with a multi-line DETAIL string viewable via
`RET' in the *tip-log* buffer."
  (when (tip-log--passes-p level tip-log-min-level)
    (let* ((msg (apply #'format fmt args))
           (entry (make-tip-log-entry
                   :time (float-time)
                   :level level
                   :category category
                   :message msg
                   :detail detail
                   :file (tip-log--current-file)
                   :backend (tip-log--current-backend))))
      (tip-log--push entry)
      (when (tip-log--passes-p level tip-log-echo-level)
        (tip-log--echo level category msg))
      (when (eq level 'error)
        (display-warning 'tip msg :warning)))))

(defun tip-log--echo (level category msg)
  "Mirror an entry to the echo area with severity-colored prefix.
The `tip[level/category]:' prefix picks up the level face
(error → red, warning → amber, info → default, debug → shadow);
MSG inherits the same face so a long compile error reads as a
single colored chunk in *Messages* and is easy to skim."
  (let* ((face (tip-log--face-for level))
         (prefix (propertize (format "tip[%s/%s]:" level category)
                             'face face))
         (body (propertize msg 'face face)))
    ;; `(message "%s" propertized)' preserves text properties — the
    ;; echo area honors `face' and `*Messages*' picks up the same.
    (message "%s %s" prefix body)))

;;; * protocol scrubbing

(defun tip-log--scrub-value (key val)
  "Return a display-safe representation of VAL under KEY.
Fields in `tip-log-protocol-scrub-fields' are replaced with byte-size
markers; long strings are truncated; vectors and lists collapse to
length summaries."
  (cond
   ((memq (intern-soft (format "%s" key)) tip-log-protocol-scrub-fields)
    (cond
     ((stringp val) (format "<%dB>" (string-bytes val)))
     ((null val)    "null")
     (t             (format "<%S>" (type-of val)))))
   ((stringp val)
    (if (> (length val) tip-log-protocol-truncate)
        (concat (substring val 0 tip-log-protocol-truncate) "…")
      val))
   ((vectorp val)
    (format "[%d items]" (length val)))
   ((and (listp val) (not (null val)))
    (format "(%d items)" (length val)))
   (t val)))

(defun tip-log--summarize-params (params)
  "Render PARAMS (an alist or plist or vector) as a compact one-line
string suitable for the message column.  Long fields are stripped."
  (cond
   ((null params) "—")
   ((and (listp params) (consp (car params)) (atom (caar params)))
    ;; alist
    (mapconcat (lambda (kv)
                 (format "%s=%s"
                         (car kv)
                         (tip-log--scrub-value (car kv) (cdr kv))))
               params ", "))
   (t (format "%S" params))))

(defun tip-log-protocol (direction method id params)
  "Log a protocol message at debug level under category `protocol'.
DIRECTION is `send' or `recv'.  METHOD is the JSON-RPC method name
or response kind.  ID is the request id (integer).  PARAMS is the
alist (or vector / plist) of params or result fields.

The full PARAMS structure is preserved as the entry's detail (viewable
via `RET' in *tip-log*); the short message column shows only a
scrubbed summary so the table stays readable and recording stays cheap."
  (when (tip-log--passes-p 'debug tip-log-min-level)
    (let* ((arrow (if (eq direction 'send) "→" "←"))
           (summary (tip-log--summarize-params params))
           (entry (make-tip-log-entry
                   :time (float-time)
                   :level 'debug
                   :category 'protocol
                   :message (format "%s %s id=%s %s" arrow method id summary)
                   :detail (when params (format "%S" params))
                   :file (tip-log--current-file)
                   :backend (tip-log--current-backend))))
      (tip-log--push entry))))

;;; * tabulated-list view

(defvar tip-log--filter-level nil
  "Buffer-local: only show entries at or above this level (nil = all).")

(defvar tip-log--filter-category nil
  "Buffer-local: only show entries with this category (nil = all).")

(defvar tip-log--filter-file nil
  "Buffer-local: only show entries whose `file' equals this full path
(nil = all).")

(defvar tip-log--filter-backend nil
  "Buffer-local: only show entries with this backend symbol (nil = all).")

(defun tip-log--format-time (epoch)
  (format-time-string "%H:%M:%S.%3N" (seconds-to-time epoch)))

(defun tip-log--filtered-entries ()
  "Return the entry list filtered by the current buffer's filters."
  (let ((lv tip-log--filter-level)
        (cat tip-log--filter-category)
        (file tip-log--filter-file)
        (backend tip-log--filter-backend))
    (cl-remove-if-not
     (lambda (e)
       (and (or (null lv) (tip-log--passes-p (tip-log-entry-level e) lv))
            (or (null cat) (eq (tip-log-entry-category e) cat))
            (or (null file)
                (let ((ef (tip-log-entry-file e)))
                  (and ef (string= ef file))))
            (or (null backend)
                (let ((eb (tip-log-entry-backend e)))
                  ;; Tolerate string-form backends from older entries
                  ;; that pre-date symbol coercion in
                  ;; `tip-log--current-backend'.
                  (or (eq eb backend)
                      (and (stringp eb)
                           (string= eb (symbol-name backend))))))))
     tip-log--entries)))

(defun tip-log--tabulated-entries ()
  "Build `tabulated-list-entries' from the filtered ring."
  (let ((entries (tip-log--filtered-entries))
        (i 0)
        out)
    (dolist (e entries)
      (let* ((face (tip-log--face-for (tip-log-entry-level e)))
             (file (tip-log-entry-file e))
             (file-cell (if file (file-name-nondirectory file) ""))
             (backend (tip-log-entry-backend e))
             (backend-cell (cond ((null backend) "")
                                 ((symbolp backend) (symbol-name backend))
                                 (t (format "%s" backend)))))
        (push
         (list i
               (vector
                (propertize (tip-log--format-time (tip-log-entry-time e))
                            'face 'shadow)
                (propertize (symbol-name (tip-log-entry-level e))
                            'face face)
                (propertize (symbol-name (tip-log-entry-category e))
                            'face 'font-lock-type-face)
                (propertize backend-cell 'face 'font-lock-keyword-face)
                (propertize file-cell 'face 'font-lock-string-face
                            'help-echo file)
                (propertize (tip-log-entry-message e)
                            'face face
                            'tip-log-entry e)))
         out)
        (cl-incf i)))
    (nreverse out)))

(defvar tip-log-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "L") #'tip-log-filter-level)
    (define-key map (kbd "C") #'tip-log-filter-category)
    (define-key map (kbd "f") #'tip-log-filter-file)
    (define-key map (kbd "B") #'tip-log-filter-backend)
    (define-key map (kbd "F") #'tip-log-clear-filters)
    (define-key map (kbd "k") #'tip-log-clear)
    (define-key map (kbd "RET") #'tip-log-show-detail)
    (define-key map (kbd "e") #'tip-log-cycle-echo-level)
    (define-key map (kbd "m") #'tip-log-cycle-min-level)
    map)
  "Keymap for `tip-log-mode'.")

(define-derived-mode tip-log-mode tabulated-list-mode "tip-log"
  "Major mode for the *tip-log* buffer.

Bindings:
  \\[tabulated-list-sort]    sort by current column
  \\[tip-log-filter-level]   filter by level
  \\[tip-log-filter-category] filter by category
  \\[tip-log-clear-filters]  clear filters
  \\[tip-log-clear]          drop all entries
  \\[tip-log-show-detail]    show full detail (for protocol payloads)
  \\[revert-buffer]          refresh"
  (setq tabulated-list-format
        [("Time"     12 t)
         ("Level"     8 t)
         ("Category" 12 t)
         ("Backend"   8 t)
         ("File"     20 t)
         ("Message"   0 t)])
  (setq tabulated-list-sort-key '("Time" . t)) ; reverse = newest first
  (setq-local revert-buffer-function (lambda (&rest _) (tip-log--refresh)))
  (tabulated-list-init-header))

(defun tip-log--refresh ()
  "Rebuild the *tip-log* buffer from the current entry ring."
  (when (derived-mode-p 'tip-log-mode)
    (setq tabulated-list-entries (tip-log--tabulated-entries))
    (let ((point (point)))
      (tabulated-list-print t)
      (goto-char (min point (point-max))))
    (tip-log--update-header-line)))

(defun tip-log--update-header-line ()
  (setq header-line-format
        (concat
         (format " %d entries · rec≥%s · echo≥%s"
                 (length tip-log--entries)
                 tip-log-min-level
                 tip-log-echo-level)
         (when tip-log--filter-level
           (format " | level≥%s" tip-log--filter-level))
         (when tip-log--filter-category
           (format " | cat=%s" tip-log--filter-category))
         (when tip-log--filter-backend
           (format " | be=%s" tip-log--filter-backend))
         (when tip-log--filter-file
           (format " | file=%s" tip-log--filter-file))
         (format "  | %s lvl %s cat %s be %s file %s clr %s clr-flt %s rec %s echo %s detail"
                 (propertize "L" 'face 'help-key-binding)
                 (propertize "C" 'face 'help-key-binding)
                 (propertize "B" 'face 'help-key-binding)
                 (propertize "f" 'face 'help-key-binding)
                 (propertize "k" 'face 'help-key-binding)
                 (propertize "F" 'face 'help-key-binding)
                 (propertize "m" 'face 'help-key-binding)
                 (propertize "e" 'face 'help-key-binding)
                 (propertize "RET" 'face 'help-key-binding)))))

(defun tip-log--refresh-buffer-if-visible ()
  "Refresh the *tip-log* buffer when it's already showing — keeps a
visible log live without paying the cost when it's hidden."
  (let ((buf (get-buffer "*tip-log*")))
    (when (and buf (get-buffer-window buf t))
      (with-current-buffer buf
        (tip-log--refresh)))))

;;; * commands

(defconst tip-log--levels '(debug info warning error)
  "Severity levels in ascending order.  Used by the cycle commands.")

(defun tip-log--cycle-next (level)
  "Return the next level after LEVEL, wrapping around."
  (let* ((rest (cdr (memq level tip-log--levels))))
    (or (car rest) (car tip-log--levels))))

;;;###autoload
(defun tip-log-set-echo-level (level)
  "Set `tip-log-echo-level' to LEVEL interactively.
LEVEL is one of `debug', `info', `warning', or `error'."
  (interactive
   (list (intern (completing-read
                  (format "Echo level (currently %s): " tip-log-echo-level)
                  '("debug" "info" "warning" "error") nil t))))
  (setq tip-log-echo-level level)
  (message "tip-log echo level: %s" level))

;;;###autoload
(defun tip-log-set-min-level (level)
  "Set `tip-log-min-level' to LEVEL interactively.
LEVEL is one of `debug', `info', `warning', or `error'.  Entries
below this severity are dropped at the source — changing this
won't surface earlier entries, but it caps the cost going forward."
  (interactive
   (list (intern (completing-read
                  (format "Min recording level (currently %s): " tip-log-min-level)
                  '("debug" "info" "warning" "error") nil t))))
  (setq tip-log-min-level level)
  (message "tip-log min recording level: %s" level))

;;;###autoload
(defun tip-log-cycle-echo-level ()
  "Cycle `tip-log-echo-level' through debug → info → warning → error → debug.
Convenient bind for a quickly-accessible toggle."
  (interactive)
  (setq tip-log-echo-level (tip-log--cycle-next tip-log-echo-level))
  (message "tip-log echo level: %s" tip-log-echo-level))

;;;###autoload
(defun tip-log-cycle-min-level ()
  "Cycle `tip-log-min-level' through the four severity levels.
Bumping it to `debug' is the quickest way to start collecting
protocol traces in *tip-log*; bumping back to `info' or higher
silences the chatter again."
  (interactive)
  (setq tip-log-min-level (tip-log--cycle-next tip-log-min-level))
  (message "tip-log min recording level: %s" tip-log-min-level))

;;;###autoload
(defun tip-show-log ()
  "Pop to the *tip-log* buffer."
  (interactive)
  (let ((buf (tip-log--ensure-buffer)))
    (with-current-buffer buf
      (tip-log--refresh))
    (pop-to-buffer buf)))

(defun tip-log-clear ()
  "Drop every entry from the log."
  (interactive)
  (setq tip-log--entries nil)
  (tip-log--refresh-buffer-if-visible)
  (message "tip-log cleared."))

(defalias 'tip-clear-log #'tip-log-clear)

(defun tip-log-filter-level (level)
  "Show only entries at or above LEVEL.  With prefix arg, clear filter."
  (interactive
   (list (if current-prefix-arg
             nil
           (intern (completing-read
                    "Minimum level: "
                    '("debug" "info" "warning" "error")
                    nil t)))))
  (setq-local tip-log--filter-level level)
  (tip-log--refresh))

(defun tip-log-filter-category (category)
  "Show only entries with CATEGORY.  With prefix arg, clear filter."
  (interactive
   (list (if current-prefix-arg
             nil
           (intern (completing-read
                    "Category: "
                    (delete-dups
                     (mapcar (lambda (e)
                               (symbol-name (tip-log-entry-category e)))
                             tip-log--entries))
                    nil t)))))
  (setq-local tip-log--filter-category category)
  (tip-log--refresh))

(defun tip-log-filter-file (file)
  "Show only entries whose `file' equals FILE.
Candidates are the full paths of file-associated entries already in
the log; minibuffer completion (e.g. ido / vertico / fido) handles
substring / basename matching.  With prefix arg, clear the filter."
  (interactive
   (list (if current-prefix-arg
             nil
           (completing-read
            "File: "
            (delete-dups
             (cl-loop for e in tip-log--entries
                      for f = (tip-log-entry-file e)
                      when f collect f))
            nil t))))
  (setq-local tip-log--filter-file
              (and file (not (string-empty-p file)) file))
  (tip-log--refresh))

(defun tip-log-filter-backend (backend)
  "Show only entries whose `backend' is BACKEND.  With prefix arg, clear."
  (interactive
   (list (if current-prefix-arg
             nil
           (intern (completing-read
                    "Backend: "
                    (delete-dups
                     (cl-loop for e in tip-log--entries
                              for b = (tip-log-entry-backend e)
                              when b
                              collect (cond ((symbolp b) (symbol-name b))
                                            (t (format "%s" b)))))
                    nil t)))))
  (setq-local tip-log--filter-backend backend)
  (tip-log--refresh))

(defun tip-log-clear-filters ()
  "Drop all active filters in the *tip-log* buffer."
  (interactive)
  (setq-local tip-log--filter-level nil)
  (setq-local tip-log--filter-category nil)
  (setq-local tip-log--filter-file nil)
  (setq-local tip-log--filter-backend nil)
  (tip-log--refresh))

(defun tip-log-show-detail ()
  "Show the full detail (e.g. unscrubbed protocol payload) of the
entry at point in a side buffer."
  (interactive)
  (let* ((entry (get-text-property
                 (save-excursion (beginning-of-line) (point))
                 'tip-log-entry)))
    ;; tabulated-list applies the property to each cell; find any cell
    ;; on the current line.
    (unless entry
      (let ((eol (line-end-position)))
        (save-excursion
          (beginning-of-line)
          (while (and (< (point) eol) (not entry))
            (setq entry (get-text-property (point) 'tip-log-entry))
            (forward-char 1)))))
    (cond
     ((not entry)
      (user-error "No entry at point"))
     ((not (tip-log-entry-detail entry))
      (message "No detail recorded for this entry."))
     (t
      (let ((buf (get-buffer-create "*tip-log-detail*")))
        (with-current-buffer buf
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (format "Time:     %s\nLevel:    %s\nCategory: %s\nMessage:  %s\n\n--- detail ---\n%s\n"
                            (tip-log--format-time (tip-log-entry-time entry))
                            (tip-log-entry-level entry)
                            (tip-log-entry-category entry)
                            (tip-log-entry-message entry)
                            (tip-log-entry-detail entry))))
          (special-mode))
        (display-buffer buf))))))

(provide 'tip-log)

;;; tip-log.el ends here
