;; Bufferline: a tab per open buffer on the top row.
;;
;; The focused tab is highlighted. When the tabs do not fit, a window of them
;; is shown (core/fit.scm) with the number of hidden tabs on each side, and the
;; window moves only as far as it must to keep the focused tab in view.

(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "../core/host.scm")
(require "../core/theme.scm")
(require "../core/draw.scm")
(require "../core/text.scm")
(require "../core/fit.scm")
(require "../icons/icons.scm")

(provide bufferline-enable!)

;; 'multiple: shown while two or more buffers are open; 'always
(define *mode* 'multiple)
;; first tab of the window shown last frame
(define *first* 0)
;; clickable spans of the last frame: list of (from to doc-id)
(define *spans* '())
;; columns for the hidden-tab counter on each side
(define *counter-width* 4)

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

(define (buffers) (or (safe editor-all-documents) '()))

(define (height)
  (if (or (equal? *mode* 'always) (>= (length (buffers)) 2)) 1 0))

(define (buffer-path doc) (safe (lambda () (editor-document->path doc))))

(define (buffer-label doc)
  (define path (buffer-path doc))
  (if path (file-name path) "[scratch]"))

(define (index-of x xs)
  (let loop ([xs xs] [i 0])
    (cond [(null? xs) #f]
          [(equal? (car xs) x) i]
          [else (loop (cdr xs) (+ i 1))])))

;;; one tab

;; (cap . body): the end glyphs' style and the tab's own style
(define (tab-styles base active?)
  (define fill (if active?
                   (class-color 'blue)
                   (or (style->bg (theme-scope-ref "ui.statusline.inactive"))
                       (style->bg (theme-scope-ref "ui.statusline")))))
  (define text (if active? (style->bg base) (class-color 'grey)))
  (define body (let ([s (if fill (style-bg base fill) base)]) (if text (style-fg s text) s)))
  (cons (if fill (style-fg base fill) base) body))

;; label-width: #f, or a width to shorten the name to
(define (tab-fragments doc active? base label-width)
  (define styles (tab-styles base active?))
  (define body (cdr styles))
  (define path (buffer-path doc))
  (define name (buffer-label doc))
  (define unsaved? (safe (lambda () (editor-document-dirty? doc))))
  (define icon (and path (file-icon name)))
  (pill-fragments
   (append (list (cons " " #f))
           ;; on the highlighted tab the icon takes the tab's text colour
           (if icon
               (list (cons (icon-glyph icon) (if active? #f (icon-style icon body))) (cons " " #f))
               '())
           (list (cons (if label-width (truncate-text name label-width) name) #f))
           (if unsaved?
               (let ([mark (ui-icon 'unsaved)])
                 (list (cons " " #f) (cons (icon-glyph mark) (if active? #f (icon-style mark body)))))
               '())
           (list (cons " " #f)))
   (car styles)
   body))

;;; the bar

(define (render a frame)
  (define x0 (area-x a))
  (define y (area-y a))
  (define width (area-width a))
  (define base (theme-scope-ref "ui.background"))
  (define dim (let ([c (class-color 'grey)]) (if c (style-fg base c) base)))
  (fill-row! frame x0 y width base)
  (define docs (buffers))
  (define focused (safe (lambda () (editor->doc-id (editor-focus)))))
  (define focus (or (index-of focused docs) 0))
  (define frags (map (lambda (d) (tab-fragments d (equal? d focused) base #f)) docs))
  (define widths (map fragments-width frags))
  (define all-fit? (<= (apply + widths) width))
  (define budget (if all-fit? width (max 1 (- width (* 2 *counter-width*)))))
  (define window (if all-fit? (cons 0 (length docs)) (tab-window widths focus *first* budget)))
  (set! *first* (car window))
  (define left-x (if all-fit? x0 (+ x0 *counter-width*)))
  ;; a focused tab wider than the room gets a shorter name
  (define overflow (if (null? widths) 0 (- (list-ref widths focus) budget)))
  (define (frags-at i)
    (if (and (= i focus) (> overflow 0))
        (tab-fragments (list-ref docs i) #t base (max 1 (- (text-width (buffer-label (list-ref docs i))) overflow)))
        (list-ref frags i)))
  (set! *spans*
        (let loop ([i (car window)] [x left-x] [acc '()])
          (if (>= i (cdr window))
              acc
              (let ([end (draw-fragments! frame x y (- (+ left-x budget) x) (frags-at i) base)])
                (loop (+ i 1) end (cons (list x end (list-ref docs i)) acc))))))
  (unless all-fit?
    (define hidden-left (car window))
    (define hidden-right (- (length docs) (cdr window)))
    ;; a counter jumps to the nearest hidden buffer on its side
    (when (> hidden-left 0)
      (frame-set-string! frame x0 y (string-append "‹" (number->string hidden-left)) dim)
      (set! *spans* (cons (list x0 left-x (list-ref docs (- hidden-left 1))) *spans*)))
    (when (> hidden-right 0)
      (define label (string-append (number->string hidden-right) "›"))
      (frame-set-string! frame (- (+ x0 width) (text-width label)) y label dim)
      (set! *spans* (cons (list (- (+ x0 width) *counter-width*) (+ x0 width) (list-ref docs (cdr window)))
                          *spans*)))))

(define (on-mouse event _area)
  (when (equal? (event-mouse-kind event) 0)
    (define col (event-mouse-col event))
    (define hit (filter (lambda (s) (and (>= col (car s)) (< col (cadr s)))) *spans*))
    (when (pair? hit)
      (safe (lambda () (editor-switch-action! (caddr (car hit)) (Action/Replace))))))
  event-result/consume)

(define *enabled?* #f)

(define (bufferline-enable! [mode 'multiple])
  (set! *mode* mode)
  (unless *enabled?*
    (set! *enabled?* #t)
    ;; this bar replaces the native one on the same row
    (safe (lambda () (bufferline "never")))
    ;; opening or closing a buffer can show or hide the bar
    (register-hook 'document-opened (lambda (_) (host-sync!)))
    (register-hook 'document-closed (lambda (_) (host-sync!)))
    (register-part! (make-part 'bufferline 'bar 'top
                               #:size height
                               #:render render
                               #:mouse on-mouse
                               #:order 10))))
