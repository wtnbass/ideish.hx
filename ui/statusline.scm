;; Statusline: one bar above the command line for the focused view.
;;
;; Left: the mode and the file. Right: segments for the agent, git,
;; diagnostics, selections, language servers, language and position. When the
;; bar is too narrow, whole right-hand segments are dropped, least important
;; first (core/fit.scm), and the file path is shortened last.

(require "helix/components.scm")
(require "helix/configuration.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require-builtin helix/core/text as text.)
(require "../core/host.scm")
(require "../core/theme.scm")
(require "../core/draw.scm")
(require "../core/text.scm")
(require "../core/fit.scm")
(require "../core/watch.scm")
(require "../icons/icons.scm")
(require "../agent/state.scm")

(provide statusline-enable!)

(define *gap* "  ")

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

(define (focused-doc) (safe (lambda () (editor->doc-id (editor-focus)))))

(define (tinted base class)
  (define c (class-color class))
  (if c (style-fg base c) base))

;; priority: higher stays longer when the bar is narrow
(struct segment (priority frags))

;;; left side

(define *modes*
  (list (list (string->editor-mode "insert") "INSERT" "ui.statusline.insert" 'green)
        (list (string->editor-mode "select") "SELECT" "ui.statusline.select" 'purple)))

(define (mode-label base)
  (define current (editor-mode))
  (define entry (let loop ([ms *modes*])
                  (cond [(null? ms) #f]
                        [(equal? (car (car ms)) current) (car ms)]
                        [else (loop (cdr ms))])))
  (define name (if entry (cadr entry) "NORMAL"))
  (define scope (theme-scope-ref (if entry (caddr entry) "ui.statusline.normal")))
  (define fill (or (style->bg scope) (class-color (if entry (cadddr entry) 'blue))))
  (define text (or (style->fg scope) (style->bg base)))
  (define body (let ([s (if fill (style-bg base fill) base)]) (if text (style-fg s text) s)))
  (pill-fragments (list (cons (string-append " " name " ") (style-with-bold body)))
                  (if fill (style-fg base fill) base)
                  body))

(define (file-label base)
  (define doc (focused-doc))
  (define path (and doc (safe (lambda () (editor-document->path doc)))))
  (cond
    [(not path) (list (cons "[scratch]" (tinted base 'grey)))]
    [else
     (define icon (file-icon (file-name path)))
     (define unsaved? (safe (lambda () (editor-document-dirty? doc))))
     (append (list (cons (icon-glyph icon) (icon-style icon base))
                   (cons " " #f)
                   (cons (relative-path path (helix-find-workspace)) #f))
             (if unsaved?
                 (let ([mark (ui-icon 'unsaved)]) (list (cons " " #f) (cons (icon-glyph mark) (icon-style mark base))))
                 '()))]))

;;; right side, in display order

(define (agent-part base)
  (define state (agent-indicator))
  (and state (segment 8 (list (cons (car state) (tinted base (cdr state)))))))

(define (git-part base)
  (define branch (git-branch))
  (and branch
       (not (equal? branch ""))
       (let* ([icon (ui-icon 'git-branch)]
              [counts (string-append (if (> (git-ahead) 0) (string-append " ↑" (number->string (git-ahead))) "")
                                     (if (> (git-behind) 0) (string-append " ↓" (number->string (git-behind))) ""))])
         (segment 6 (list (cons (string-append (icon-glyph icon) " " branch counts) (icon-style icon base)))))))

;; counts: (hint info warning error)
(define (diagnostics-part base)
  (define doc (focused-doc))
  (define counts (and doc (safe (lambda () (editor-document-diagnostic-counts doc)))))
  (define shown
    (if counts
        (filter (lambda (x) (> (car x) 0)) (list (cons (list-ref counts 3) 'error) (cons (list-ref counts 2) 'warning)))
        '()))
  (and (pair? shown)
       (segment 7 (foldl (lambda (x acc)
                           (define icon (ui-icon (cdr x)))
                           (append acc
                                   (if (null? acc) '() (list (cons " " #f)))
                                   (list (cons (string-append (icon-glyph icon) " " (number->string (car x)))
                                               (icon-style icon base)))))
                         '()
                         shown))))

(define (selections-part base)
  (define sel (safe current-selection-object))
  (define count (if sel (length (selection->ranges sel)) 1))
  (and (> count 1)
       (segment 5 (list (cons (string-append (number->string (+ 1 (selection->primary-index sel))) "/"
                                             (number->string count) " sel")
                              (tinted base 'grey))))))

;; language servers, dimmed until they finish starting
(define (servers-part base)
  (define clients (or (safe get-active-lsp-clients) '()))
  (and (pair? clients)
       (segment 3 (foldl (lambda (c acc)
                           (define ready? (safe (lambda () (lsp-client-initialized? c))))
                           (append acc
                                   (if (null? acc) '() (list (cons " " #f)))
                                   (list (cons (or (safe (lambda () (lsp-client-name c))) "?")
                                               (tinted base (if ready? 'blue 'grey))))))
                         '()
                         clients))))

(define (language-part base)
  (define doc (focused-doc))
  (define language (and doc (safe (lambda () (editor-document->language doc)))))
  (segment 4 (list (cons (or language "text") (tinted base 'grey)))))

(define (position-part base)
  (define doc (focused-doc))
  (define line (+ 1 (get-current-line-number)))
  (define lines (or (and doc (safe (lambda () (text.rope-len-lines (editor->text doc))))) 0))
  (define column (+ 1 (get-current-column-number)))
  (segment 9 (list (cons (string-append (number->string line) ":" (number->string column)
                                        (if (> lines 0)
                                            (string-append " " (number->string (quotient (* 100 line) lines)) "%")
                                            ""))
                         (tinted base 'purple)))))

(define (right-segments base)
  (filter (lambda (s) s)
          (list (agent-part base)
                (git-part base)
                (diagnostics-part base)
                (selections-part base)
                (servers-part base)
                (language-part base)
                (position-part base))))

;;; the bar

;; the theme's statusline colours, so the bar marks the editor's bottom edge
;; above the terminal; ui.background when the theme gives the bar no background
(define (bar-style)
  (define bar (theme-scope-ref "ui.statusline"))
  (if (style->bg bar) bar (theme-scope-ref "ui.background")))

(define (render a frame)
  (define x (area-x a))
  (define y (area-y a))
  (define width (area-width a))
  (define base (bar-style))
  (fill-row! frame x y width base)
  (define mode (mode-label base))
  (define file (file-label base))
  (define segments (right-segments base))
  ;; the left side keeps the mode and at least a short file name
  (define left-min (+ (fragments-width mode) (text-width *gap*) (min 16 (fragments-width file))))
  (define kept (fit-segments (map (lambda (s) (cons (segment-priority s) (fragments-width (segment-frags s)))) segments)
                             (text-width *gap*) left-min (- width 1)))
  (define right
    (foldl (lambda (i acc)
             (append acc (if (null? acc) '() (list (cons *gap* #f))) (segment-frags (list-ref segments i))))
           '()
           kept))
  (define right-width (fragments-width right))
  (define after-mode (draw-fragments! frame x y width mode base))
  (define file-x (+ after-mode (text-width *gap*)))
  (draw-fragments! frame file-x y (max 0 (- (+ x width) right-width file-x 2)) file base)
  (draw-fragments! frame (- (+ x width) right-width 1) y right-width right base))

(define *enabled?* #f)

(define (statusline-enable!)
  (unless *enabled?*
    (set! *enabled?* #t)
    ;; empty the native statusline; this bar is drawn over the last view's row
    (statusline #:left '() #:center '() #:right '())
    (watch-start!)
    (register-part! (make-part 'statusline 'bar 'bottom
                               #:size (lambda () 1)
                               #:render render))))
