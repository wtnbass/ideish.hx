;; Terminal pane: a shell at the bottom, below the statusline and Helix's
;; message row. The : prompt covers its last row while it is open.
;;
;; The shell runs on a PTY owned by the native library, which emulates it on a
;; Rust thread and publishes the screen as rows of styled runs. The shared
;; tick takes them on Helix's main thread and turns them into fragments; the
;; render only draws the fragments taken last.
;;
;; Every key goes to the shell, Esc included; C-\ hands the keys back to the
;; editor.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require "../core/host.scm")
(require "../core/tick.scm")
(require "../core/text.scm")

(#%require-dylib "libideish"
                 (only-in terminal-spawn
                          terminal-poll!
                          terminal-rows
                          terminal-cursor
                          terminal-exit-code
                          terminal-key!
                          terminal-paste!
                          terminal-resize!
                          terminal-scroll!
                          terminal-kill!))

(provide terminal-enable!
         terminal-health-lines)

;;; settings

;; rows
(define *height* 12)
;; #f, or a list: program and arguments, instead of $SHELL
(define *command* #f)

;;; state

(define *term* #f)
;; list of rows, each a list of (col text . style)
(define *lines* '())
;; (column row) or #f
(define *cursor* #f)
(define *program* "")
;; (cols . rows) last sent to the emulator
(define *size* #f)
;; top-left of the pane, for the cursor
(define *origin* #f)

(define (command-line)
  (or *command*
      (let ([shell (maybe-get-env-var "SHELL")])
        (list (if (Ok? shell) (Ok->value shell) "/bin/sh")))))

(define (basename path)
  (define parts (split-many path "/"))
  (if (null? parts) path (last parts)))

;;; colours

(define *rgb-base* 16777216) ; RGB_BASE in native/src/terminal.rs

(define (color-of n)
  (cond
    [(< n 0) #f]
    [(< n 256) (Color/Indexed n)]
    [else
     (let ([v (modulo n *rgb-base*)])
       (Color/rgb (quotient v 65536) (modulo (quotient v 256) 256) (modulo v 256)))]))

(define (flag? flags bit) (odd? (quotient flags bit)))

;; base: the pane's style, which gives the default colours. A run whose style
;; cannot be built is drawn in it, so one bad run does not stop the screen
(define (run-style base fg bg flags)
  (with-handler (lambda (_) base) (build-style base fg bg flags)))

(define (build-style base fg bg flags)
  (let* ([s base]
         [s (let ([c (color-of fg)]) (if c (style-fg s c) s))]
         [s (let ([c (color-of bg)]) (if c (style-bg s c) s))]
         [s (if (flag? flags 1) (style-with-bold s) s)]
         [s (if (flag? flags 2) (style-with-italics s) s)]
         [s (if (flag? flags 4) (style-with-dim s) s)]
         [s (if (flag? flags 8) (style-underline-style s Underline/Line) s)]
         [s (if (flag? flags 16) (style-with-reversed s) s)]
         [s (if (flag? flags 32) (style-with-crossed-out s) s)])
    s))

(define (pane-style) (theme-scope-ref "ui.background"))

;; rows: what terminal-rows returns, lists of runs (col text fg bg flags)
(define (row-lines rows)
  (define base (pane-style))
  (map (lambda (row)
         (map (lambda (run)
                (cons (list-ref run 0)
                      (cons (list-ref run 1)
                            (run-style base (list-ref run 2) (list-ref run 3) (list-ref run 4)))))
              row))
       rows))

;;; process

(define (stop!)
  (when *term*
    (terminal-kill! *term*)
    (set! *term* #f))
  (set! *lines* '())
  (set! *cursor* #f)
  (set! *size* #f))

(define (on-exit! code)
  (stop!)
  (host-hide! 'terminal)
  (set-status! (string-append "terminal: " *program* " exited"
                              (if (= code 0) "" (string-append " (code " (number->string code) ")")))))

;; tick task: #t while the shell is printing
(define (poll)
  (and *term*
       (let ([changed (terminal-poll! *term*)])
         (when changed
           (set! *lines* (row-lines (terminal-rows *term*)))
           (set! *cursor* (terminal-cursor *term*)))
         (let ([code (terminal-exit-code *term*)])
           (when code (on-exit! code)))
         changed)))

(define *tick-registered?* #f)

(define (start!)
  (unless *term*
    (define cmd (command-line))
    (define rows (max 1 *height*))
    (define t (terminal-spawn (car cmd) (string-join (cdr cmd) "\n") (helix-find-workspace) 80 rows))
    (cond
      [(string? t)
       (set-status! (string-append "terminal: " t))
       ;; on-show runs while the pane is being shown and focused; close it after
       (enqueue-thread-local-callback (lambda () (host-hide! 'terminal)))]
      [else
       (set! *term* t)
       (set! *program* (basename (car cmd)))
       (set! *size* (cons 80 rows))
       (unless *tick-registered?*
         (set! *tick-registered?* #t)
         (tick-register! poll))
       (tick-wake!)])))

;;; keys

(define (key-name event)
  (cond
    [(key-event-enter? event) "enter"]
    [(key-event-tab? event) "tab"]
    [(key-event-backspace? event) "backspace"]
    [(key-event-escape? event) "escape"]
    [(key-event-left? event) "left"]
    [(key-event-right? event) "right"]
    [(key-event-up? event) "up"]
    [(key-event-down? event) "down"]
    [(key-event-home? event) "home"]
    [(key-event-end? event) "end"]
    [(key-event-page-up? event) "page-up"]
    [(key-event-page-down? event) "page-down"]
    [(key-event-delete? event) "delete"]
    [(key-event-insert? event) "insert"]
    [else
     (let loop ([n 1])
       (cond
         [(> n 12) #f]
         [(key-event-F? event n) (string-append "f" (number->string n))]
         [else (loop (+ n 1))]))]))

;; C-\ reaches Helix as Ctrl-\, or as Ctrl-4 from terminals that send it as
;; the control byte 0x1c
(define (leave-key? event ch)
  (and (equal? (key-event-modifier event) key-modifier-ctrl)
       (or (equal? ch #\\) (equal? ch #\4))))

(define (on-key event)
  (define ch (and (key-event? event) (key-event-char event)))
  (cond
    [(not *term*) #f]
    [(paste-event? event) (terminal-paste! *term* (paste-event-string event)) event-result/consume]
    [(not (key-event? event)) event-result/consume]
    [(leave-key? event ch) (host-blur!) event-result/consume]
    [else
     (define mods (or (key-event-modifier event) 0))
     (cond
       [(char? ch) (terminal-key! *term* (string ch) mods (string ch))]
       [(key-name event) (terminal-key! *term* (key-name event) mods "")]
       [else void])
     (tick-wake!)
     event-result/consume]))

;;; mouse

(define (on-mouse event _a)
  (define kind (event-mouse-kind event))
  (cond
    [(not *term*) void]
    [(equal? kind 11) (terminal-scroll! *term* -3)]
    [(equal? kind 10) (terminal-scroll! *term* 3)]
    [(equal? kind 0)
     (unless (host-focused? 'terminal)
       (enqueue-thread-local-callback (lambda () (host-focus! 'terminal))))]
    [else void])
  event-result/consume)

;;; drawing

(define (render a frame)
  (define x (area-x a))
  (define y (area-y a))
  (define w (area-width a))
  (define rows (area-height a))
  (buffer/clear-with frame a (pane-style))
  (set! *origin* (cons x y))
  (when (and *term* (> w 0) (> rows 0) (not (equal? *size* (cons w rows))))
    (set! *size* (cons w rows))
    (terminal-resize! *term* w rows))
  (let loop ([ls *lines*] [i 0])
    (when (and (pair? ls) (< i rows))
      (for-each (lambda (run)
                  (define col (car run))
                  (when (< col w)
                    (frame-set-string! frame (+ x col) (+ y i)
                                       (truncate-text (cadr run) (- w col))
                                       (cddr run))))
                (car ls))
      (loop (cdr ls) (+ i 1)))))

(define (cursor)
  (and *cursor* *origin*
       (position (+ (cdr *origin*) (cadr *cursor*))
                 (+ (car *origin*) (car *cursor*)))))

;;; health

(define (terminal-health-lines)
  (list (string-append "shell: " (string-join (command-line) " "))))

;;; setup

(define *enabled?* #f)

;; height: rows. command: #f, or a list of strings to
;; start instead of $SHELL
(define (terminal-enable! #:height [height 12] #:command [command #f])
  (set! *height* height)
  (set! *command* command)
  (unless *enabled?*
    (set! *enabled?* #t)
    (register-part! (make-part 'terminal 'pane 'bottom
                               #:size (lambda () *height*)
                               #:render render
                               #:mouse on-mouse
                               #:key on-key
                               #:cursor cursor
                               #:on-show start!))))
