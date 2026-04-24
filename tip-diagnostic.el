;;; tip-diagnostic.el --- Health check + bug-report tarball -*- lexical-binding: t; -*-

;; Commentary:
;;
;; Two user-facing commands:
;;
;;   `tip-doctor'       — probe tip-server + external deps, print a report.
;;   `tip-bug-report'   — collect project files + dump doctor output into a
;;                        tarball suitable for attaching to an issue.
;;
;; Backend-specific file-enumeration lives in tip-diagnostic-latex.el and
;; tip-diagnostic-typst.el; both ultimately ask the server (via the
;; `list_project_files' request) for the connected component.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(declare-function tip--send-request "tip-server-proc")
(declare-function tip-active-backend "tip-backend")
(declare-function tip-backend-name   "tip-backend")

;;; ------------------------------------------------------------
;;; Doctor (formerly in tip.el)

;;;###autoload
(defun tip-doctor ()
  "Probe tip-server and external deps; print a diagnostic report.
Useful for interactive troubleshooting and as the body of a bug report —
the report includes server version, OS/arch, backend statuses, dep
paths and versions, plus any warnings.

If no server is running, one is started for the probe.  Output goes to
the `*tip-doctor*' buffer."
  (interactive)
  (tip--send-request
   "health_check" nil
   (lambda (result)
     (tip--doctor-render result))))

(defun tip--doctor-render (result)
  "Format health-check RESULT into the `*tip-doctor*' buffer."
  (let* ((report (alist-get 'report result))
         (buf (get-buffer-create "*tip-doctor*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (tip--doctor-format report))
      (goto-char (point-min))
      (special-mode))
    (display-buffer buf)))

(defun tip--doctor-insert (text &rest faces)
  "Insert TEXT propertized with FACES."
  (insert (propertize text 'face (if (cdr faces) faces (car faces)))))

(defun tip--doctor-mark (ok)
  "Return a propertized check/cross glyph for OK."
  (if ok
      (propertize "✓" 'face 'success)
    (propertize "✗" 'face 'error)))

(defun tip--doctor-kv (label value &optional face)
  "Insert `  LABEL  VALUE' line; VALUE rendered with FACE (default shadow)."
  (insert "  ")
  (tip--doctor-insert (format "%-16s" label) 'font-lock-variable-name-face)
  (tip--doctor-insert (format "%s\n" (or value "—"))
                      (or face 'shadow)))

(defun tip--doctor-dep (label probe)
  "Insert a dependency line for PROBE under LABEL."
  (let* ((found (eq (alist-get 'found probe) t))
         (meets (not (eq (alist-get 'meets_min_version probe) :json-false)))
         (ok (and found meets))
         (ver (alist-get 'version probe))
         (path (alist-get 'path probe)))
    (insert "    ")
    (insert (tip--doctor-mark ok))
    (insert " ")
    (tip--doctor-insert (format "%-12s" label) 'font-lock-function-name-face)
    (cond
     ((not found)
      (tip--doctor-insert "not found\n" 'error))
     (t
      (tip--doctor-insert (format "%s" (or ver "(version unknown)"))
                          'font-lock-constant-face)
      (unless meets
        (insert " ")
        (tip--doctor-insert "(below minimum)" 'warning))
      (insert "\n")
      (when path
        (tip--doctor-insert (format "                 %s\n" path) 'shadow))))))

(defun tip--doctor-section (title ok)
  "Insert a section header TITLE with OK status mark."
  (insert "\n")
  (insert (tip--doctor-mark ok))
  (insert " ")
  (tip--doctor-insert title 'font-lock-keyword-face)
  (insert "\n"))

(defun tip--doctor-format (r)
  "Insert a formatted report from the alist R."
  (cl-labels ((field (k) (alist-get k r))
              (sub (a k) (alist-get k a)))
    (tip--doctor-insert "  tip-server health check\n" '(bold font-lock-keyword-face))
    (tip--doctor-insert (make-string 40 ?─) 'shadow)
    (insert "\n\n")
    (tip--doctor-kv "Server"   (field 'server_version) 'font-lock-constant-face)
    (tip--doctor-kv "Target"   (field 'target_triple))
    (tip--doctor-kv "Platform" (format "%s / %s" (field 'os) (field 'arch)))
    (let ((tp (field 'typst)))
      (when tp
        (tip--doctor-section "Typst backend" (eq (sub tp 'ok) t))
        (tip--doctor-kv "typst" (sub tp 'typst_version) 'font-lock-constant-face)
        (tip--doctor-kv "fonts" (format "%d" (sub tp 'fonts_found)))))
    (let ((lx (field 'latex)))
      (when lx
        (tip--doctor-section "LaTeX backend" (eq (sub lx 'ok) t))
        (tip--doctor-dep "latex"       (sub lx 'latex))
        (tip--doctor-dep "dvisvgm"     (sub lx 'dvisvgm))
        (tip--doctor-dep "preview.sty" (sub lx 'preview_sty))))
    (let ((ws (field 'warnings)))
      (when (and ws (> (length ws) 0))
        (insert "\n")
        (tip--doctor-insert "Warnings\n" '(bold warning))
        (mapc (lambda (w)
                (insert "  ")
                (tip--doctor-insert "!" 'warning)
                (insert " " w "\n"))
              (append ws nil))))))

(defun tip--doctor-plain-text (result)
  "Return a non-propertized rendering of RESULT, for inclusion in a tarball."
  (with-temp-buffer
    (tip--doctor-format (alist-get 'report result))
    (buffer-substring-no-properties (point-min) (point-max))))

;;; ------------------------------------------------------------
;;; Bug-report tarball

(defcustom tip-bug-report-directory
  (expand-file-name "tip-bug-reports" (temporary-file-directory))
  "Directory where `tip-bug-report' writes tarballs."
  :type 'directory
  :group 'tip)

(defvar tip-diagnostic-collectors
  '((typst . tip-diagnostic-typst-collect)
    (latex . tip-diagnostic-latex-collect))
  "Alist mapping backend name symbol → `(URI CALLBACK)' collector.
The collector must call CALLBACK with `(root . files)'.")

;;;###autoload
(defun tip-bug-report ()
  "Pack the current buffer's project into a tarball for bug reporting.
Dispatches to the backend-specific collector in
`tip-diagnostic-collectors', shows the file list, and on confirmation
writes a tarball under `tip-bug-report-directory' along with the
`tip-doctor' output."
  (interactive)
  (let* ((uri (buffer-file-name))
         (backend (tip--current-backend-name))
         (collector (cdr (assq backend tip-diagnostic-collectors))))
    (unless uri
      (user-error "Current buffer is not visiting a file"))
    (unless collector
      (user-error "No diagnostic collector registered for backend: %s" backend))
    ;; Lazy-load the backend module.
    (require (intern (format "tip-diagnostic-%s" backend)))
    (funcall (symbol-function collector)
             uri
             (lambda (root-and-files)
               (tip--bug-report-after-collect backend uri root-and-files)))))

(defun tip--bug-report-after-collect (backend uri root-and-files)
  "Continue `tip-bug-report' with the collector's ROOT-AND-FILES for URI."
  (let* ((root (car root-and-files))
         (files (cdr root-and-files))
         (existing (seq-filter #'file-exists-p files))
         (missing  (seq-difference files existing))
         (common-root (tip--diag-common-ancestor (cons root existing))))
    (unless existing
      (user-error "Collector returned no files for %s" uri))
    (when (tip--diag-confirm-files backend common-root existing missing)
      (tip--send-request
       "health_check" nil
       (lambda (hc)
         (tip--bug-report-write backend common-root existing hc))))))

(defun tip--current-backend-name ()
  "Return the active backend's name symbol, or nil."
  (when-let* ((b (and (fboundp 'tip-active-backend) (tip-active-backend))))
    (tip-backend-name b)))

(defun tip--diag-common-ancestor (paths)
  "Deepest directory that contains every path in PATHS."
  (let* ((dirs (mapcar (lambda (p)
                         (file-name-as-directory
                          (if (file-directory-p p) p (file-name-directory p))))
                       paths))
         (split (mapcar (lambda (d) (split-string d "/" t)) dirs))
         (n (apply #'min (mapcar #'length split)))
         (common nil))
    (cl-loop for i from 0 below n
             for heads = (mapcar (lambda (parts) (nth i parts)) split)
             while (cl-every (lambda (h) (equal h (car heads))) heads)
             do (push (car heads) common))
    (concat "/" (mapconcat #'identity (nreverse common) "/"))))

(defun tip--diag-confirm-files (backend root files missing)
  "Display FILES (relative to ROOT) and prompt yes/no.
BACKEND is the backend name symbol.  MISSING is a list of paths the
server reported but that don't exist on disk (shown in red as a hint,
not included in the tarball)."
  (let ((buf (get-buffer-create "*tip-bug-report*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (tip--doctor-insert
         (format "  tip-bug-report — %s backend\n" (or backend "?"))
         '(bold font-lock-keyword-face))
        (tip--doctor-insert (make-string 50 ?─) 'shadow)
        (insert "\n\n")
        (tip--doctor-insert "Root: " 'font-lock-variable-name-face)
        (tip--doctor-insert (format "%s\n\n" root) 'font-lock-constant-face)
        (tip--doctor-insert (format "Files (%d):\n" (length files))
                            'font-lock-variable-name-face)
        (dolist (f files)
          (let* ((rel (file-relative-name f root))
                 (escapes (string-prefix-p "../" rel)))
            (insert "  ")
            (tip--doctor-insert (if escapes "!" "·")
                                (if escapes 'warning 'shadow))
            (insert " " rel)
            (when escapes
              (insert " ")
              (tip--doctor-insert "(outside root)" 'warning))
            (insert "\n")))
        (when missing
          (insert "\n")
          (tip--doctor-insert
           (format "Missing on disk (%d, skipped):\n" (length missing))
           'warning)
          (dolist (m missing)
            (insert "  ")
            (tip--doctor-insert "✗" 'error)
            (insert " ")
            (tip--doctor-insert (file-relative-name m root) 'shadow)
            (insert "\n")))
        (insert "\n")
        (tip--doctor-insert "Also included: " 'font-lock-variable-name-face)
        (tip--doctor-insert "tip-doctor.txt\n" 'shadow)
        (goto-char (point-min)))
      (special-mode))
    (display-buffer buf))
  (y-or-n-p (format "Pack %d file%s into tarball? "
                    (length files) (if (= (length files) 1) "" "s"))))

(defun tip--bug-report-write (backend root files hc-result)
  "Write a tarball for BACKEND anchored at ROOT containing FILES.
HC-RESULT is the health-check response, dumped as tip-doctor.txt."
  (unless (file-directory-p tip-bug-report-directory)
    (make-directory tip-bug-report-directory t))
  (let* ((stamp (format-time-string "%Y%m%d-%H%M%S"))
         (base (format "tip-bug-%s-%s" (or backend "buf") stamp))
         (staging (file-name-as-directory
                   (make-temp-file (concat base "-") t)))
         (inner (file-name-as-directory
                 (expand-file-name base staging)))
         (tarball (expand-file-name (concat base ".tar.gz")
                                    tip-bug-report-directory)))
    (make-directory inner t)
    ;; Copy each file preserving its path relative to ROOT.  Paths that
    ;; escape ROOT (shouldn't happen after common-ancestor promotion,
    ;; but defensive) are copied to _outside_root/ so they're obvious.
    (dolist (f files)
      (let* ((rel (file-relative-name f root))
             (dest (if (string-prefix-p "../" rel)
                       (expand-file-name
                        (concat "_outside_root/"
                                (file-name-nondirectory f))
                        inner)
                     (expand-file-name rel inner))))
        (make-directory (file-name-directory dest) t)
        (copy-file f dest t)))
    ;; Dump doctor output.
    (with-temp-file (expand-file-name "tip-doctor.txt" inner)
      (insert (tip--doctor-plain-text hc-result)))
    ;; Pack.
    (let ((default-directory staging))
      (call-process "tar" nil nil nil
                    "-czf" tarball "--" base))
    (delete-directory staging t)
    (message "tip-bug-report: wrote %s (%d file%s)"
             tarball (length files)
             (if (= (length files) 1) "" "s"))
    (when (fboundp 'dired-jump)
      (dired-jump nil tarball))))

(provide 'tip-diagnostic)

;;; tip-diagnostic.el ends here
