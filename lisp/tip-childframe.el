;;; tip-childframe.el --- Childframe display for inline previews -*- lexical-binding: t; -*-

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Minimal childframe for displaying SVG/image previews near the cursor.
;; Inspired by eldoc-box, but specialized for image display.
;;
;; The childframe pins to a configurable corner of the parent frame
;; (`tip-childframe-position').
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
  '((t :inherit default))
  "Face for the childframe border.
Inherits `default' so the childframe is borderless by default — set
`:background' on this face if you want a visible separator.")

(defface tip-childframe-body
  '((t :inherit default))
  "Face for the childframe body.")

(defcustom tip-childframe-position 'at-point
  "Where to place the childframe relative to the parent frame.
`at-point' anchors just below the line containing the anchor position
passed to `tip-childframe-show' (point if none) — org-latex-preview-live
style.  Corner values (`top-right', etc.) pin to that frame corner."
  :type '(choice (const :tag "Below the anchor position" at-point)
                 (const :tag "Top-right corner" top-right)
                 (const :tag "Top-left corner" top-left)
                 (const :tag "Bottom-right corner" bottom-right)
                 (const :tag "Bottom-left corner" bottom-left))
  :group 'tip-childframe)

(defcustom tip-childframe-max-pixel-width 600
  "Maximum width of the childframe in pixels."
  :type 'integer
  :group 'tip-childframe)

(defcustom tip-childframe-max-pixel-height 400
  "Maximum height of the childframe in pixels."
  :type 'integer
  :group 'tip-childframe)

(defcustom tip-childframe-offset '(16 16 16)
  "Pixel offset from edges: (LEFT RIGHT TOP).
Used in corner mode to keep childframe away from frame borders."
  :type '(list (integer :tag "Left")
               (integer :tag "Right")
               (integer :tag "Top"))
  :group 'tip-childframe)

(defcustom tip-childframe-scale 2.0
  "Scale factor for SVG display in the childframe, relative to the
buffer font size.  1.0 matches the inline overlay size; 2.0 doubles it.
The effective scale is buffer-font-pt / 11 * tip-childframe-scale,
so the preview grows with the buffer font."
  :type 'float
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
    (internal-border-width . 0)
    (child-frame-border-width . 0)
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

(defun tip-childframe--position-at-point (width height anchor-pos)
  "Compute (X . Y) just below the line containing ANCHOR-POS.
ANCHOR-POS is a buffer position in the selected window.  Falls back
to the top-right corner when ANCHOR-POS isn't visible (e.g. point
scrolled offscreen).  Clamps so the childframe stays inside the
parent frame; flips above the line when there's not enough room
below."
  (let* ((posn (and anchor-pos (posn-at-point anchor-pos)))
         (xy   (and posn (posn-x-y posn))))
    (if (not xy)
        ;; Off-screen — degrade to top-right corner.
        (pcase-let ((`(,_ ,off-r ,off-t) tip-childframe-offset))
          (cons (- (frame-outer-width) width off-r) off-t))
      (let* ((edges    (window-pixel-edges))
             (win-x    (nth 0 edges))
             (win-y    (nth 1 edges))
             (line-h   (default-line-height))
             (frame-w  (frame-pixel-width))
             (frame-h  (frame-pixel-height))
             (anchor-x (+ win-x (car xy)))
             (anchor-y (+ win-y (cdr xy)))
             (below-y  (+ anchor-y line-h 4))
             ;; Flip above the line if the childframe would clip the
             ;; bottom of the parent frame.
             (y (if (> (+ below-y height) frame-h)
                    (max 0 (- anchor-y height 4))
                  below-y))
             (x (max 0 (min anchor-x (- frame-w width)))))
        (cons x y)))))

(defun tip-childframe--position (width height &optional anchor-pos)
  "Compute (X . Y) at the configured corner or near ANCHOR-POS.
Respects `tip-childframe-offset' for padding from edges."
  (pcase-let ((`(,off-l ,off-r ,off-t) tip-childframe-offset))
    (let ((frame-w (frame-outer-width))
          (frame-h (frame-outer-height)))
      (pcase tip-childframe-position
        ('at-point     (tip-childframe--position-at-point width height anchor-pos))
        ('top-right    (cons (- frame-w width off-r) off-t))
        ('top-left     (cons off-l off-t))
        ('bottom-right (cons (- frame-w width off-r) (- frame-h height off-t)))
        ('bottom-left  (cons off-l (- frame-h height off-t)))
        (_             (cons (- frame-w width off-r) off-t))))))

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
      (when (frame-parent frame)
        (redirect-frame-focus frame (frame-parent frame))))
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

(defun tip-childframe--update-geometry (frame width height &optional anchor-pos)
  "Resize and reposition FRAME to WIDTH x HEIGHT.
ANCHOR-POS, when non-nil and `tip-childframe-position' is `at-point',
anchors the frame just below that buffer position."
  (let ((pos (tip-childframe--position width height anchor-pos)))
    (set-frame-size frame width height t)
    (set-frame-position frame (car pos) (cdr pos))))

;;; * public API

(defun tip-childframe-show (svg-data &optional anchor-pos)
  "Show SVG-DATA in a childframe near the cursor.
ANCHOR-POS, when non-nil and `tip-childframe-position' is `at-point',
places the frame just below the line containing that buffer
position (default: point).  Sized by `tip-childframe-scale' times the
buffer-font ratio, so the preview scales with font size rather than
the SVG's native 11pt."
  (let* ((buf (tip-childframe--ensure-buffer))
         (font-pt (if (fboundp 'tip--font-size-pt)
                      (tip--font-size-pt)
                    11.0))
         (scale (* (or tip-childframe-scale 1.0) (/ font-pt 11.0)))
         (scaled-max-w (round (* tip-childframe-max-pixel-width scale)))
         (scaled-max-h (round (* tip-childframe-max-pixel-height scale)))
         (img (list 'image
                    :type 'svg
                    :data svg-data
                    :max-width scaled-max-w
                    :max-height scaled-max-h
                    :scale scale
                    :ascent 'center))
         (size (image-size img t))
         (w (min scaled-max-w (+ (car size) 4)))
         (h (min scaled-max-h (+ (cdr size) 4))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert-image img)
        (insert "\n"))
      (setq buffer-read-only t))
    (let ((frame (tip-childframe--get-frame buf)))
      (tip-childframe--update-geometry frame w h (or anchor-pos (point)))
      (make-frame-visible frame))))

(defun tip-childframe-show-text (text &optional face anchor-pos)
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
      (tip-childframe--update-geometry frame w h (or anchor-pos (point)))
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
