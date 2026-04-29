;;; tip-jump.el --- Avy-style jump to math/figure fragments -*- lexical-binding: t; -*-

;;; Commentary:

;; Avy-style fragment navigation: shows labels on visible fragments,
;; narrows by key presses, jumps when one candidate remains.  Used as
;; an alternative to plain cursor movement when a buffer has many
;; fragments.
;;
;; Single user-facing entry point: `tip-jump'.

;;; Code:

(require 'cl-lib)

(declare-function preview-toggle-open-at-point "preview-toggle")

(defcustom tip-jump-keys "asdfjkl;ghqweruioptyzxcvbnm"
  "Characters used for avy-style jump labels, in priority order.
Home row first for qwerty ergonomics."
  :type 'string
  :group 'tip)

;;;###autoload
(defun tip-jump ()
  "Jump to a math/figure fragment using avy-style tree selection.
Shows labels on visible fragments. Press a key to narrow candidates;
if one remains, jump. Otherwise show next level and read again."
  (interactive)
  (let* ((ovs (seq-filter
               (lambda (ov)
                 (and (eq (overlay-get ov 'tip) 'tip)
                      (overlay-get ov 'display)
                      (let ((start (overlay-start ov)))
                        (and (>= start (window-start))
                             (<= start (window-end))))))
               (overlays-in (point-min) (point-max))))
         (n (length ovs)))
    (when (= n 0)
      (user-error "No visible fragments to jump to"))
    (when (= n 1)
      (goto-char (overlay-start (car ovs)))
      (preview-toggle-open-at-point)
      (cl-return-from tip-jump))
    ;; Build tree paths: assign each candidate a sequence of keys
    (let* ((keys tip-jump-keys)
           (nkeys (length keys))
           (paths (tip-jump--build-paths n nkeys))
           (candidates (cl-mapcar #'cons paths ovs)))
      (tip-jump--select candidates keys))))

(defun tip-jump--build-paths (n nkeys)
  "Build N tree paths using NKEYS branching factor.
Returns a list of strings, each a sequence of key indices."
  (let ((depth (max 1 (ceiling (log n nkeys))))
        (paths nil))
    ;; Generate paths breadth-first
    (dotimes (i n)
      (let ((path "")
            (idx i))
        (dotimes (_ depth)
          (setq path (concat (string (% idx nkeys)) path))
          (setq idx (/ idx nkeys)))
        (push path paths)))
    (nreverse paths)))

(defun tip-jump--select (candidates keys)
  "Interactively narrow CANDIDATES by reading keys.
Each candidate is (PATH . OVERLAY) where PATH is a string of key indices."
  (let ((label-ovs nil))
    (unwind-protect
        (catch 'done
          (while (> (length candidates) 1)
            ;; Show current labels
            (dolist (lov label-ovs) (delete-overlay lov))
            (setq label-ovs nil)
            (dolist (cand candidates)
              (let* ((path (car cand))
                     (ov (cdr cand))
                     ;; Show the first unconsumed key as the label
                     (key-idx (aref path 0))
                     (label (string (aref keys key-idx)))
                     (label-ov (make-overlay (overlay-start ov)
                                             (1+ (overlay-start ov)))))
                (overlay-put label-ov 'display
                             (propertize (format " %s " label)
                                         'face '(:background "#ff6600"
                                                 :foreground "white"
                                                 :weight bold)))
                (overlay-put label-ov 'priority 100)
                (push label-ov label-ovs)))
            (redisplay t)
            ;; Read one key
            (let* ((char (read-char "tip-jump:"))
                   (key-pos (cl-position char keys)))
              (unless key-pos
                (throw 'done nil)) ;; invalid key, cancel
              ;; Filter candidates matching this key at position 0
              (setq candidates
                    (cl-loop for cand in candidates
                             when (= (aref (car cand) 0) key-pos)
                             collect (cons (substring (car cand) 1)
                                          (cdr cand))))))
          ;; One candidate left
          (when (= (length candidates) 1)
            (let ((target-ov (cdar candidates)))
              (goto-char (overlay-start target-ov))
              (preview-toggle-open-at-point))))
      ;; Cleanup
      (dolist (lov label-ovs)
        (delete-overlay lov)))))

(provide 'tip-jump)

;;; tip-jump.el ends here
