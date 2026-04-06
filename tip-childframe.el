;;; tip-childframe.el --- Childframe display for inline previews -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Minimal childframe for displaying SVG/image previews near the cursor.
;; Inspired by eldoc-box, but specialized for image display.
;;
;; Provides two display modes (customizable via `tip-childframe-position'):
;;   - 'at-point: childframe follows cursor (like eldoc-box-hover-at-point-mode)
;;   - 'corner: childframe stays at window corner (like eldoc-box-hover-mode)
;;
;; Usage:
;;   (tip-childframe-show svg-data)   ; show SVG
;;   (tip-childframe-show-text text)  ; show text (e.g. errors)
;;   (tip-childframe-hide)            ; hide the frame

;;; Code:

(defgroup tip-childframe nil
  "Childframe for TIP preview display."
  :group 'tip)

(defface tip-childframe-border
  '((((background light)) :background "#c0c0c0")
    (t :background "#555555"))
  "Face for the childframe border.")

(defface tip-childframe-body
  '((t :inherit default))
  "Face for the childframe body.")

(defcustom tip-childframe-position 'at-point
  "Where to display the childframe.
`at-point' follows the cursor. `corner' stays at the upper-right."
  :type '(choice (const :tag "Follow cursor" at-point)
                 (const :tag "Window corner" corner))
  :group 'tip-childframe)

(defcustom tip-childframe-max-pixel-width 600
  "Maximum width of the childframe in pixels."
  :type 'integer
  :group 'tip-childframe)

(defcustom tip-childframe-max-pixel-height 400
  "Maximum height of the childframe in pixels."
  :type 'integer
  :group 'tip-childframe)

(defvar tip-childframe--frame nil
  "The childframe for preview.")

(defvar tip-childframe--buffer nil
  "Buffer displayed in the childframe.")

(defvar tip-childframe--frame-parameters
  '((no-accept-focus . t)
    (no-focus-on-map . t)
    (min-width . 0)
    (min-height . 0)
    (internal-border-width . 1)
    (left-fringe . 0)
    (right-fringe . 0)
    (vertical-scroll-bars . nil)
    (horizontal-scroll-bars . nil)
    (menu-bar-lines . 0)
    (tool-bar-lines . 0)
    (tab-bar-lines . 0)
    (undecorated . t)
    (unsplittable . t)
    (no-other-frame . t)
    (no-special-glyphs . t)
    (cursor-type . nil))
  "Frame parameters for the childframe.")

;;; * positioning

(defun tip-childframe--at-point-position (width height)
  "Compute (X . Y) position for childframe below cursor."
  (let* ((pos (window-absolute-pixel-position))
         (x (or (car pos) 0))
         (y (or (cdr pos) 0))
         (line-h (default-line-height))
         (frame-w (frame-pixel-width))
         (frame-h (frame-pixel-height)))
    ;; Place below cursor, shift left if would overflow right edge
    (cons (min x (max 0 (- frame-w width 10)))
          ;; Place below cursor, or above if no room below
          (if (< (+ y line-h height 10) frame-h)
              (+ y line-h 4)
            (max 0 (- y height 4))))))

(defun tip-childframe--corner-position (width _height)
  "Compute (X . Y) position for childframe at upper-right corner."
  (let* ((edges (window-absolute-pixel-edges))
         (right (nth 2 edges))
         (top (nth 1 edges)))
    (cons (max 0 (- right width 10))
          (+ top 10))))

(defun tip-childframe--position (width height)
  "Compute position based on `tip-childframe-position'."
  (pcase tip-childframe-position
    ('at-point (tip-childframe--at-point-position width height))
    ('corner (tip-childframe--corner-position width height))
    (_ (tip-childframe--at-point-position width height))))

;;; * frame management

(defun tip-childframe--ensure-buffer ()
  "Return the childframe buffer, creating if needed."
  (unless (buffer-live-p tip-childframe--buffer)
    (setq tip-childframe--buffer
          (get-buffer-create " *tip-childframe*"))
    (with-current-buffer tip-childframe--buffer
      (setq-local mode-line-format nil)
      (setq-local header-line-format nil)
      (setq-local cursor-type nil)
      (setq-local cursor-in-non-selected-windows nil)
      (setq-local left-fringe-width 0)
      (setq-local right-fringe-width 0)))
  tip-childframe--buffer)

(defun tip-childframe--get-frame (buf)
  "Return the childframe displaying BUF, creating if needed."
  (let* ((params (append tip-childframe--frame-parameters
                         `((parent-frame . ,(selected-frame))
                           (default-minibuffer-frame . ,(selected-frame))
                           (minibuffer . ,(minibuffer-window)))))
         window frame)
    (if (and tip-childframe--frame
             (frame-live-p tip-childframe--frame))
        (progn
          (setq frame tip-childframe--frame)
          (setq window (frame-selected-window frame))
          (set-frame-parameter frame 'parent-frame (selected-frame)))
      ;; Create new frame
      (setq window (display-buffer-in-child-frame
                    buf `((child-frame-parameters . ,params))))
      (setq frame (window-frame window))
      (set-window-dedicated-p window t)
      (redirect-frame-focus frame (frame-parent frame)))
    ;; Style
    (set-face-attribute 'internal-border frame
                        :inherit 'tip-childframe-border)
    (when (facep 'child-frame-border)
      (set-face-background 'child-frame-border
                           (face-attribute 'tip-childframe-border
                                           :background nil t)
                           frame))
    (setq tip-childframe--frame frame)
    frame))

(defun tip-childframe--update-geometry (frame width height)
  "Resize and reposition FRAME to WIDTH x HEIGHT."
  (let ((pos (tip-childframe--position width height)))
    (set-frame-size frame width height t)
    (set-frame-position frame (car pos) (cdr pos))))

;;; * public API

(defun tip-childframe-show (svg-data)
  "Show SVG-DATA in a childframe near the cursor."
  (let* ((buf (tip-childframe--ensure-buffer))
         (img (list 'image
                    :type 'svg
                    :data svg-data
                    :max-width tip-childframe-max-pixel-width
                    :max-height tip-childframe-max-pixel-height
                    :ascent 'center))
         (size (image-size img t))
         (w (min tip-childframe-max-pixel-width (+ (car size) 8)))
         (h (min tip-childframe-max-pixel-height (+ (cdr size) 8))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image img)
        (insert "\n"))
      (setq buffer-read-only t))
    (let ((frame (tip-childframe--get-frame buf)))
      (tip-childframe--update-geometry frame w h)
      (make-frame-visible frame))))

(defun tip-childframe-show-text (text &optional face)
  "Show TEXT in the childframe. Optional FACE for styling."
  (let* ((buf (tip-childframe--ensure-buffer))
         (str (if face (propertize text 'face face) text))
         (w (min tip-childframe-max-pixel-width
                 (+ (* (min (length text) 80) (frame-char-width)) 16)))
         (h (+ (* (1+ (cl-count ?\n text)) (frame-char-height)) 8)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert str)
        (insert "\n"))
      (setq buffer-read-only t))
    (let ((frame (tip-childframe--get-frame buf)))
      (tip-childframe--update-geometry frame w h)
      (make-frame-visible frame))))

(defun tip-childframe-hide ()
  "Hide the childframe."
  (when (frame-live-p tip-childframe--frame)
    (make-frame-invisible tip-childframe--frame)))

(defun tip-childframe-cleanup ()
  "Destroy the childframe and buffer."
  (when (frame-live-p tip-childframe--frame)
    (delete-frame tip-childframe--frame))
  (setq tip-childframe--frame nil)
  (when (buffer-live-p tip-childframe--buffer)
    (kill-buffer tip-childframe--buffer))
  (setq tip-childframe--buffer nil))

(provide 'tip-childframe)

;;; tip-childframe.el ends here
