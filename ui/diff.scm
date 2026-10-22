;; Diff view: a file against HEAD, drawn over the editor's area.
;;
;; The diff comes from `git diff` (diff/model.scm). Both sides of it are parsed
;; with the file's grammar, so the rows keep their syntax colours
;; (diff/highlight.scm), and the rows are tinted with the theme's diff.plus and
;; diff.minus. When git reports a change, the diff is taken again.
;;
;; The colours are worked out in a callback of their own, after the rows are
;; shown: the query must not run inside with-handler (diff/highlight.scm), and
;; the host wraps every key handler and render in one.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require "../core/host.scm")
(require "../core/theme.scm")
(require "../core/draw.scm")
(require "../core/text.scm")
(require "../core/watch.scm")
(require "../icons/icons.scm")
(require "../diff/model.scm")
(require "../diff/highlight.scm")

(provide diff-show!
         diff-show-current!
         diff-shown-path)

(define *path* #f)
(define *rows* (list->vector '()))
(define *counts* (cons 0 0))
(define *number-width* 1)
;; line -> runs (start end scope), for each side
(define *old-lines* (hash))
(define *new-lines* (hash))
;; bumped on every load, so a highlight callback for an older load does nothing
(define *generation* 0)
(define *revision* -1)
(define *cursor* 0)
(define *scroll* 0)
(define *list-height* 20)
;; scope -> style, rebuilt every frame so a theme change shows at once
(define *styles* (hash))

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

(define (root) (helix-find-workspace))

;;; reading the diff

;; stdout of git run in the workspace; stderr is dropped so it does not land
;; on the screen
(define (git-output args)
  (define child (spawn-process (with-current-dir (with-stderr-piped (with-stdout-piped (command "git" args)))
                                                 (root))))
  (or (and (Ok? child)
           (let ([out (wait->stdout (Ok->value child))]) (and (Ok? out) (Ok->value out))))
      ""))

(define (read-text path)
  (or (safe (lambda ()
              (let* ([port (open-input-file path)]
                     [s (read-port-to-string port)])
                (close-input-port port)
                s)))
      ""))

;; the line ranges one side shows, as (first . last), one per hunk
(define (side-ranges rows line-of)
  (let loop ([rs rows] [current #f] [acc '()])
    (cond
      [(null? rs) (reverse (if current (cons current acc) acc))]
      [(equal? (drow-kind (car rs)) 'hunk) (loop (cdr rs) #f (if current (cons current acc) acc))]
      [else
       (let ([l (line-of (car rs))])
         (if l
             (loop (cdr rs) (if current (cons (car current) l) (cons l l)) acc)
             (loop (cdr rs) current acc)))])))

(define (load! path)
  (define rel (relative-path path (root)))
  (define untracked? (equal? (git-status-of path) 'untracked))
  (define rows
    (parse-diff (git-output (append (list "--no-optional-locks" "diff" "--no-color" "--no-ext-diff")
                                    (if untracked?
                                        (list "--no-index" "--" "/dev/null" rel)
                                        (list "HEAD" "--" rel))))))
  (define old-text (if untracked? "" (git-output (list "show" (string-append "HEAD:./" rel)))))
  (define new-text (if (path-exists? path) (read-text path) ""))
  (define lang (language-for-path path))
  (set! *path* path)
  (set! *rows* (list->vector rows))
  (set! *counts* (diff-counts rows))
  (set! *number-width*
        (foldl (lambda (r acc)
                 (max acc
                      (string-length (number->string (or (drow-old r) 0)))
                      (string-length (number->string (or (drow-new r) 0)))))
               1
               rows))
  (set! *old-lines* (hash))
  (set! *new-lines* (hash))
  (set! *revision* (git-revision))
  (set! *generation* (+ *generation* 1))
  (set-cursor! *cursor*)
  (let ([generation *generation*])
    (enqueue-thread-local-callback
     (lambda ()
       (when (= generation *generation*)
         (set! *old-lines* (highlight-lines old-text lang (side-ranges rows drow-old)))
         (set! *new-lines* (highlight-lines new-text lang (side-ranges rows drow-new))))))))

;;; cursor and scrolling

(define (row-count) (vector-length *rows*))
(define (row-at i) (and (>= i 0) (< i (row-count)) (vector-ref *rows* i)))

(define (set-cursor! i)
  (set! *cursor* (max 0 (min i (max 0 (- (row-count) 1)))))
  (cond
    [(< *cursor* *scroll*) (set! *scroll* *cursor*)]
    [(>= *cursor* (+ *scroll* *list-height*)) (set! *scroll* (+ (- *cursor* *list-height*) 1))]))

(define (move! delta) (set-cursor! (+ *cursor* delta)))

(define (scroll! delta)
  (set! *scroll* (max 0 (min (+ *scroll* delta) (max 0 (- (row-count) *list-height*))))))

;; puts the next or previous hunk at the top
(define (jump-hunk! direction)
  (define hunks (hunk-indices (vector->list *rows*)))
  (define candidates (if (> direction 0)
                         (filter (lambda (i) (> i *cursor*)) hunks)
                         (reverse (filter (lambda (i) (< i *cursor*)) hunks))))
  (when (pair? candidates)
    (set-cursor! (car candidates))
    (set! *scroll* (car candidates))
    (scroll! 0)))

;;; leaving the view

;; the line of the working file a row stands for: a deleted row goes to the
;; line that now follows it
(define (target-line i)
  (let loop ([j i])
    (define r (row-at j))
    (cond
      [(not r) 1]
      [(drow-new r) (max 1 (drow-new r))]
      [else (loop (+ j 1))])))

(define (close!)
  (if (host-shown? 'tree) (host-focus! 'tree) (host-blur!))
  (host-hide! 'diff))

(define (open-at-cursor!)
  (define path *path*)
  (define line (target-line *cursor*))
  (cond
    [(not (path-exists? path)) (set-status! "diff: the file is deleted")]
    [else
     (host-blur!)
     (host-hide! 'diff)
     (enqueue-thread-local-callback
      (lambda ()
        (helix.open path)
        (helix.goto (number->string line))
        (align_view_center)))]))

;;; keys and mouse

(define (ctrl? event) (equal? (key-event-modifier event) key-modifier-ctrl))

(define (on-key event)
  (define ch (key-event-char event))
  (define half (max 1 (quotient *list-height* 2)))
  (cond
    [(key-event-escape? event) (close!)]
    [(and (ctrl? event) (equal? ch #\d)) (move! half)]
    [(and (ctrl? event) (equal? ch #\u)) (move! (- half))]
    [(ctrl? event) void]
    [(or (key-event-down? event) (equal? ch #\j)) (move! 1)]
    [(or (key-event-up? event) (equal? ch #\k)) (move! -1)]
    [(or (key-event-home? event) (equal? ch #\g)) (set-cursor! 0)]
    [(or (key-event-end? event) (equal? ch #\G)) (set-cursor! (- (row-count) 1))]
    [(or (equal? ch #\n) (equal? ch #\])) (jump-hunk! 1)]
    [(or (equal? ch #\N) (equal? ch #\[)) (jump-hunk! -1)]
    [(or (key-event-enter? event) (equal? ch #\o)) (open-at-cursor!)]
    [(equal? ch #\q) (close!)]
    [else void])
  event-result/consume)

(define (on-mouse event a)
  (define kind (event-mouse-kind event))
  (define i (+ *scroll* (- (event-mouse-row event) (area-y a) 1)))
  (cond
    [(equal? kind 10) (scroll! 3)]
    [(equal? kind 11) (scroll! -3)]
    [(equal? kind 0)
     (when (row-at i) (set-cursor! i))
     (unless (host-focused? 'diff)
       (enqueue-thread-local-callback (lambda () (host-focus! 'diff))))]
    [else void])
  event-result/consume)

;;; drawing

;; over mixed into under by amount, per channel; #f unless both are RGB
(define (blend over under amount)
  (define (mix a b) (exact (round (+ (* a amount) (* b (- 1 amount))))))
  (and over under (Color-red over) (Color-red under)
       (Color/rgb (mix (Color-red over) (Color-red under))
                  (mix (Color-green over) (Color-green under))
                  (mix (Color-blue over) (Color-blue under)))))

(define (tint base scope amount)
  (define bg (blend (scope-fg scope) (style->bg base) amount))
  (if bg (style-bg base bg) base))

(define (capture-style scope)
  (or (hash-try-get *styles* scope)
      (let ([s (theme-scope-ref scope)])
        (set! *styles* (hash-insert *styles* scope s))
        s)))

(define (expand-tabs s) (string-join (split-many s "\t") "    "))

;; text cut into fragments by runs (start end scope); #f styles take the base
(define (code-fragments text runs)
  (define len (string-length text))
  (define (piece from to style) (cons (expand-tabs (substring text from to)) style))
  (let loop ([rs runs] [pos 0] [acc '()])
    (if (null? rs)
        (reverse (if (< pos len) (cons (piece pos len #f) acc) acc))
        (let* ([r (car rs)]
               [from (max pos (min len (list-ref r 0)))]
               [to (max from (min len (list-ref r 1)))])
          (loop (cdr rs)
                to
                (cons (piece from to (capture-style (list-ref r 2)))
                      (if (< pos from) (cons (piece pos from #f) acc) acc)))))))

(define (pad-left s width)
  (string-append (make-string (max 0 (- width (string-length s))) #\space) s))

(define (number-text n)
  (if n (pad-left (number->string n) *number-width*) (make-string *number-width* #\space)))

(define (draw-header! frame x y width base)
  (define icon (file-icon (file-name *path*)))
  (define added (car *counts*))
  (define deleted (cdr *counts*))
  (define dim (with-class base 'grey))
  (fill-row! frame x y width base)
  (draw-fragments! frame x y width
                   (list (cons " " #f)
                         (cons (icon-glyph icon) (icon-style icon base))
                         (cons " " #f)
                         (cons (relative-path *path* (root)) (style-with-bold base))
                         (cons "  HEAD → working tree  " dim)
                         (cons (string-append "+" (number->string added)) (style-fg base (or (scope-fg "diff.plus") (style->fg base))))
                         (cons " " #f)
                         (cons (string-append "-" (number->string deleted)) (style-fg base (or (scope-fg "diff.minus") (style->fg base)))))
                   base))

(define (with-class base class)
  (define c (class-color class))
  (if c (style-fg base c) base))

(define (draw-row! frame x y width r cursor? base text-style)
  (define kind (drow-kind r))
  (define gutter-width (+ 4 (* 2 *number-width*)))
  (define dim (with-class base 'grey))
  (cond
    [(member kind '(hunk note))
     (define style (if cursor? (tint base "ui.cursorline.primary" 0.5) base))
     (fill-row! frame x y width style)
     (draw-fragments! frame x y width
                      (list (cons (make-string gutter-width #\space) #f)
                            (cons (if (equal? kind 'hunk) (string-append "⋯ " (drow-text r)) (drow-text r)) dim))
                      style)]
    [else
     (define add? (equal? kind 'add))
     (define del? (equal? kind 'del))
     (define scope (cond [add? "diff.plus"] [del? "diff.minus"] [else #f]))
     (define style (cond
                     [scope (tint base scope (if cursor? 0.32 0.16))]
                     [cursor? (let ([bg (style->bg (theme-scope-ref "ui.cursorline.primary"))]) (if bg (style-bg base bg) base))]
                     [else base]))
     (define number-style (patch-fg style (theme-scope-ref (if cursor? "ui.linenr.selected" "ui.linenr"))))
     (define sign-style (if scope (patch-fg style (theme-scope-ref scope)) style))
     (define lines (if del? *old-lines* *new-lines*))
     (define line (if del? (drow-old r) (drow-new r)))
     (fill-row! frame x y width style)
     (draw-fragments! frame x y width
                      (append (list (cons " " #f)
                                    (cons (number-text (drow-old r)) number-style)
                                    (cons " " #f)
                                    (cons (number-text (drow-new r)) number-style)
                                    (cons (cond [add? " + "] [del? " - "] [else "   "]) sign-style))
                              (code-fragments (drow-text r) (or (hash-try-get lines line) '())))
                      (patch-fg style text-style))]))

;; base with the foreground of other, when it has one
(define (patch-fg base other)
  (define fg (style->fg other))
  (if fg (style-fg base fg) base))

(define (render a frame)
  (when (and *path* (not (= *revision* (git-revision))))
    (safe (lambda () (load! *path*))))
  (set! *styles* (hash))
  (define x (area-x a))
  (define y (area-y a))
  (define w (area-width a))
  (define h (area-height a))
  (define base (theme-scope-ref "ui.background"))
  (define text-style (theme-scope-ref "ui.text"))
  (define focused? (host-focused? 'diff))
  (buffer/clear-with frame a base)
  (when *path*
    (draw-header! frame x y w base)
    (set! *list-height* (max 1 (- h 1)))
    (scroll! 0)
    (if (= (row-count) 0)
        (draw-fragments! frame x (+ y 2) w
                         (list (cons "  no changes against HEAD" (with-class base 'grey)))
                         base)
        (let loop ([i 0])
          (when (< i *list-height*)
            (define r (row-at (+ *scroll* i)))
            (when r
              (draw-row! frame x (+ y 1 i) w r (and focused? (= (+ *scroll* i) *cursor*)) base text-style)
              (loop (+ i 1))))))))

;;; showing

(define *registered?* #f)

;; The file whose diff is on screen, or #f
(define (diff-shown-path) (and (host-shown? 'diff) *path*))

;; Shows path against HEAD over the editor. focus: give the view the keys;
;; without it the keys stay where they are, e.g. in the tree.
(define (diff-show! path #:focus [focus? #t])
  (unless *registered?*
    (set! *registered?* #t)
    (register-part! (make-part 'diff 'pane 'centre
                               #:size (lambda () 1)
                               #:render render
                               #:mouse on-mouse
                               #:key on-key)))
  (unless (equal? path *path*)
    (set! *cursor* 0)
    (set! *scroll* 0))
  (with-handler (lambda (err) (set-error! (string-append "diff: " (to-string err))))
                (load! path))
  (if focus? (host-focus! 'diff) (host-show! 'diff)))

(define (diff-show-current!)
  (define path (safe cx->current-file))
  (if path
      (diff-show! path)
      (set-status! "diff: the buffer has no file")))
