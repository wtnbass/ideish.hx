;; File tree pane.
;;
;; Directory listings are cached in tree/model.scm and dropped only when the
;; watcher reports a change in that directory, so the tree follows the disk
;; without polling. Git status colours names and adds a marker on the right.
;;
;; In changes mode the pane lists the files git reports as changed instead,
;; and opens their diff against HEAD over the editor (ui/diff.scm).

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
(require "../tree/model.scm")
(require "diff.scm")

(provide tree-enable!
         tree-reveal-current!
         tree-show-changes!)

(define *side* 'left)
(define *width* 30)
(define *min-width* 16)
(define *max-width* 80)
(define *show-hidden* #t)
(define *show-ignored* #t)
;; never listed: git internals and Finder metadata
(define *always-hidden* (hash ".git" #t ".DS_Store" #t))

(define *tree* #f)
;; 'files or 'changes
(define *mode* 'files)
(define *rows* (list->vector '()))
(define *rows-dirty* #t)
(define *rows-git-revision* -1)
(define *cursor* 0)
(define *cursor-path* #f)
(define *scroll* 0)
(define *list-height* 20)

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

(define (root) (tree-root *tree*))

(define (list-dir dir)
  (or (safe (lambda () (map (lambda (p) (cons p (is-dir? p))) (read-dir dir)))) '()))

(define (skip? path name dir?)
  (or (hash-contains? *always-hidden* name)
      (and (not *show-hidden*) (starts-with? name "."))
      (and (not *show-ignored*) (equal? (effective-status path) 'ignored))))

(define (row-count) (vector-length *rows*))
(define (row-at i) (and (>= i 0) (< i (row-count)) (vector-ref *rows* i)))
(define (current-row) (row-at *cursor*))

(define (index-of-path path)
  (let loop ([i 0])
    (cond
      [(>= i (row-count)) #f]
      [(equal? (row-path (vector-ref *rows* i)) path) i]
      [else (loop (+ i 1))])))

(define (changes?) (equal? *mode* 'changes))

(define (change-rows)
  (map (lambda (e)
         (define path (car e))
         (row path (file-name path) 0 (or (safe (lambda () (is-dir? path))) #f) #f))
       (changed-paths (git-statuses) (root))))

(define (rebuild!)
  (set! *rows* (list->vector (if (changes?)
                                 (change-rows)
                                 ;; the first row is the workspace root, shown as the header instead
                                 (cdr (tree-rows *tree* list-dir skip?)))))
  (set! *rows-dirty* #f)
  (set! *rows-git-revision* (git-revision))
  (unless (changes?) (watch-set-dirs! (tree-open-dirs *tree*)))
  ;; keep the cursor on the same entry when rows move around it
  (define same (and *cursor-path* (index-of-path *cursor-path*)))
  (set-cursor! (or same (min *cursor* (max 0 (- (row-count) 1))))))

(define (ensure-rows!)
  (when (or *rows-dirty*
            (and (or (changes?) (not *show-ignored*)) (not (= *rows-git-revision* (git-revision)))))
    (rebuild!)))

(define (mark-dirty!) (set! *rows-dirty* #t))

;;; cursor and scrolling

(define (set-cursor! i)
  (set! *cursor* (max 0 (min i (max 0 (- (row-count) 1)))))
  (set! *cursor-path* (let ([r (current-row)]) (and r (row-path r))))
  (cond
    [(< *cursor* *scroll*) (set! *scroll* *cursor*)]
    [(>= *cursor* (+ *scroll* *list-height*)) (set! *scroll* (+ (- *cursor* *list-height*) 1))]))

(define (move! delta) (set-cursor! (+ *cursor* delta)))

(define (scroll! delta)
  (set! *scroll* (max 0 (min (+ *scroll* delta) (max 0 (- (row-count) *list-height*))))))

(define (center-on! i)
  (set-cursor! i)
  (set! *scroll* (max 0 (min (- i (quotient *list-height* 2)) (max 0 (- (row-count) *list-height*))))))

;;; opening

(define (focused-path)
  (safe cx->current-file))

(define (open-file! path action)
  (enqueue-thread-local-callback
   (lambda ()
     (cond
       [(equal? action 'vsplit) (helix.vsplit path)]
       [(equal? action 'hsplit) (helix.hsplit path)]
       [else (helix.open path)]))))

;; also runs when the tree is shown, so it opens on the files again after
;; :ideish-changes
(define (tree-reveal-current!)
  (when *tree*
    (set-mode! 'files)
    (define path (focused-path))
    (when (and path (path-within? path (root)))
      (tree-reveal! *tree* path)
      (rebuild!)
      (let ([i (index-of-path path)])
        (when i (center-on! i))))))

(define (toggle-dir! path)
  (tree-toggle! *tree* path)
  (rebuild!))

;;; changes

;; an untracked directory has no diff of its own
(define (show-diff! r focus?)
  (if (row-dir? r)
      (set-status! (string-append (rel (row-path r)) "/ is untracked"))
      (diff-show! (row-path r) #:focus focus?)))

;; while a diff is on screen it follows the cursor
(define (follow-diff!)
  (define r (current-row))
  (when (and (changes?) r (not (row-dir? r))
             (diff-shown-path) (not (equal? (diff-shown-path) (row-path r))))
    (show-diff! r #f)))

(define (set-mode! mode)
  (unless (equal? mode *mode*)
    (set! *mode* mode)
    (set! *scroll* 0)
    ;; a diff over the editor belongs to the changes
    (unless (changes?) (host-hide! 'diff))
    (rebuild!)))

(define (tree-show-changes!)
  (when *tree*
    ;; showing the tree switches it to the files, so the mode comes after
    (host-focus! 'tree)
    (set-mode! 'changes)))

;; action: 'open, 'vsplit or 'hsplit. In changes mode 'open shows the diff and
;; 'file opens the file.
(define (activate! action)
  (define r (current-row))
  (cond
    [(not r) void]
    [(and (changes?) (equal? action 'open)) (show-diff! r #t)]
    [(and (changes?) (row-dir? r)) void]
    [(row-dir? r) (toggle-dir! (row-path r))]
    [else
     (open-file! (row-path r) (if (equal? action 'file) 'open action))
     (host-blur!)]))

;; l: open a closed directory, step into an open one, preview a file
(define (expand-or-preview!)
  (define r (current-row))
  (cond
    [(not r) void]
    [(changes?) (show-diff! r #f)]
    [(and (row-dir? r) (not (row-open? r))) (toggle-dir! (row-path r))]
    [(row-dir? r) (let ([next (row-at (+ *cursor* 1))])
                    (when (and next (> (row-depth next) (row-depth r))) (move! 1)))]
    [else (open-file! (row-path r) 'open)]))

;; h: close an open directory, otherwise go to the parent
(define (collapse-or-parent!)
  (define r (current-row))
  (cond
    [(or (not r) (changes?)) void]
    [(and (row-dir? r) (row-open? r)) (toggle-dir! (row-path r))]
    [else (let ([i (index-of-path (parent-path (row-path r)))])
            (when i (set-cursor! i)))]))

;;; file operations

(define (run! program args)
  (define child (spawn-process (command program args)))
  (and (Ok? child) (wait (Ok->value child))))

(define (after-change! . dirs)
  (for-each (lambda (d) (tree-invalidate! *tree* d)) dirs)
  (rebuild!)
  (watch-refresh-git!))

(define (target-dir)
  (define r (current-row))
  (cond
    [(not r) (root)]
    [(row-dir? r) (row-path r)]
    [else (parent-path (row-path r))]))

(define (rel path) (if (equal? path (root)) "." (relative-path path (root))))

(define (prompt-create!)
  (define dir (target-dir))
  (push-component!
   (prompt (string-append "New in " (rel dir) "/ (end with / for a folder): ")
           (lambda (input)
             (define name (trim input))
             (unless (equal? name "")
               (define target (string-append dir "/" (trim-end-matches name "/")))
               (define folder? (ends-with? name "/"))
               (run! "mkdir" (list "-p" (if folder? target (parent-path target))))
               (unless folder?
                 (unless (path-exists? target)
                   (close-output-port (open-output-file target))))
               (tree-reveal! *tree* target)
               (after-change! dir (parent-path target))
               (let ([i (index-of-path target)]) (when i (center-on! i)))
               (unless folder?
                 (open-file! target 'open)
                 (host-blur!)))))))

(define (prompt-rename!)
  (define r (current-row))
  (when r
    (define source (row-path r))
    (define dir (parent-path source))
    (push-component!
     (prompt (string-append "Rename " (rel source) " to (relative to " (rel dir) "/): ")
             (lambda (input)
               (define name (trim input))
               (unless (or (equal? name "") (equal? name (row-name r)))
                 (define target (string-append dir "/" (trim-end-matches name "/")))
                 (run! "mkdir" (list "-p" (parent-path target)))
                 (if (path-exists? target)
                     (set-error! (string-append (rel target) " already exists"))
                     (run! "mv" (list source target)))
                 (tree-reveal! *tree* target)
                 (after-change! dir (parent-path target))
                 (let ([i (index-of-path target)]) (when i (center-on! i)))))))))

(define (confirm! message action)
  (push-component!
   (new-component! "ideish-confirm" #f
                   (lambda (_state a frame)
                     (define y (- (+ (area-y a) (area-height a)) 1))
                     (define style (theme-scope-ref "warning"))
                     (fill-row! frame (area-x a) y (area-width a) (theme-scope-ref "ui.background"))
                     (frame-set-string! frame (area-x a) y (truncate-text message (area-width a)) style))
                   (hash "handle_event"
                         (lambda (_state event)
                           (cond
                             [(mouse-event? event) event-result/consume]
                             [else
                              (when (member (key-event-char event) (list #\y #\Y))
                                (action))
                              event-result/close]))
                         "cursor" (lambda (_state _area) #f)))))

(define (confirm-delete!)
  (define r (current-row))
  (when r
    (define path (row-path r))
    (confirm! (string-append "Delete " (rel path) (if (row-dir? r) "/ and everything in it" "")
                             "? y to delete, any other key to cancel")
              (lambda ()
                (run! "rm" (list "-rf" "--" path))
                (after-change! (parent-path path))))))

;;; options

(define (set-width! w)
  (set! *width* (max *min-width* (min *max-width* w)))
  (host-sync!))

(define (toggle-hidden!)
  (set! *show-hidden* (not *show-hidden*))
  (set-status! (if *show-hidden* "tree: showing dotfiles" "tree: hiding dotfiles"))
  (rebuild!))

(define (toggle-ignored!)
  (set! *show-ignored* (not *show-ignored*))
  (set-status! (if *show-ignored* "tree: showing git-ignored files" "tree: hiding git-ignored files"))
  (rebuild!))

(define (refresh-all!)
  (tree-invalidate-all! *tree*)
  (rebuild!)
  (watch-refresh-git!))

;;; keys

(define (ctrl? event) (equal? (key-event-modifier event) key-modifier-ctrl))

(define (on-key event)
  (ensure-rows!)
  (define ch (key-event-char event))
  (define half (max 1 (quotient *list-height* 2)))
  (cond
    [(key-event-escape? event) #f]
    [(and (ctrl? event) (equal? ch #\d)) (move! half)]
    [(and (ctrl? event) (equal? ch #\u)) (move! (- half))]
    [(ctrl? event) void]
    [(or (key-event-down? event) (equal? ch #\j)) (move! 1)]
    [(or (key-event-up? event) (equal? ch #\k)) (move! -1)]
    [(or (key-event-home? event) (equal? ch #\g)) (set-cursor! 0)]
    [(or (key-event-end? event) (equal? ch #\G)) (set-cursor! (- (row-count) 1))]
    [(or (key-event-left? event) (equal? ch #\h)) (collapse-or-parent!)]
    [(or (key-event-right? event) (equal? ch #\l)) (expand-or-preview!)]
    [(key-event-enter? event) (activate! 'open)]
    [(equal? ch #\o) (activate! (if (changes?) 'file 'open))]
    [(equal? ch #\v) (activate! 'vsplit)]
    [(equal? ch #\s) (activate! 'hsplit)]
    [(equal? ch #\c) (set-mode! (if (changes?) 'files 'changes))]
    [(equal? ch #\f) (tree-reveal-current!)]
    [(equal? ch #\R) (refresh-all!)]
    [(or (equal? ch #\+) (equal? ch #\>)) (set-width! (+ *width* 2))]
    [(or (equal? ch #\-) (equal? ch #\<)) (set-width! (- *width* 2))]
    [(equal? ch #\q) (host-hide! 'tree)]
    ;; the file operations work on the directory listing
    [(changes?) void]
    [(equal? ch #\a) (prompt-create!)]
    [(equal? ch #\r) (prompt-rename!)]
    [(equal? ch #\d) (confirm-delete!)]
    [(equal? ch #\.) (toggle-hidden!)]
    [(equal? ch #\I) (toggle-ignored!)]
    [else void])
  (follow-diff!)
  (if (key-event-escape? event) #f event-result/consume))

;;; mouse

(define (on-mouse event a)
  (ensure-rows!)
  (define kind (event-mouse-kind event))
  (define i (+ *scroll* (- (event-mouse-row event) (area-y a) 1)))
  (define (focus!)
    (unless (host-focused? 'tree)
      (enqueue-thread-local-callback (lambda () (host-focus! 'tree)))))
  (cond
    [(equal? kind 10) (scroll! 3)]
    [(equal? kind 11) (scroll! -3)]
    [(and (equal? kind 0) (row-at i) (>= i *scroll*) (changes?))
     (set-cursor! i)
     (show-diff! (row-at i) #t)]
    [(and (equal? kind 0) (row-at i) (>= i *scroll*))
     (set-cursor! i)
     (let ([r (row-at i)])
       (if (row-dir? r)
           (begin (toggle-dir! (row-path r)) (focus!))
           ;; a file opens in the editor, which keeps the keys, as with Enter
           (begin (open-file! (row-path r) 'open) (host-show-editor!))))]
    ;; the header or the empty rows below the entries
    [(equal? kind 0) (focus!)]
    [else void])
  event-result/consume)

;;; drawing

(define (git-class status)
  (cond
    [(equal? status 'modified) 'yellow]
    [(or (equal? status 'added) (equal? status 'untracked)) 'green]
    [(equal? status 'deleted) 'red]
    [(equal? status 'renamed) 'blue]
    [(equal? status 'conflict) 'magenta]
    [else #f]))

(define (git-marker status)
  (cond
    [(equal? status 'modified) (ui-icon 'git-modified)]
    [(equal? status 'added) (ui-icon 'git-added)]
    [(equal? status 'untracked) (ui-icon 'git-untracked)]
    [(equal? status 'deleted) (ui-icon 'git-deleted)]
    [(equal? status 'renamed) (ui-icon 'git-renamed)]
    [(equal? status 'conflict) (ui-icon 'git-conflict)]
    [else #f]))

;; git lists an untracked or ignored directory without its contents, so
;; entries below one take its status. A directory that is untracked only for
;; the new files in it passes nothing to the tracked files beside them.
(define (effective-status path)
  (or (git-status-of path)
      (let loop ([p (parent-path path)])
        (cond
          [(or (equal? p (root)) (not (path-within? p (root)))) #f]
          [(git-untracked-dir? p) 'untracked]
          [(equal? (git-status-of p) 'ignored) 'ignored]
          [else (loop (parent-path p))]))))

(define (unsaved-paths)
  (foldl (lambda (id acc)
           (define path (safe (lambda () (editor-document->path id))))
           (if (and path (safe (lambda () (editor-document-dirty? id)))) (hash-insert acc path #t) acc))
         (hash)
         (or (safe editor-all-documents) '())))

(define (with-class base class)
  (define c (and class (class-color class)))
  (if c (style-fg base c) base))

(define (draw-header! frame x y width base)
  (define icon (ui-icon (if (changes?) 'changes 'workspace)))
  (define branch (git-branch))
  (draw-fragments! frame x y width
                   (append (list (cons " " #f)
                                 (cons (icon-glyph icon) (icon-style icon base))
                                 (cons " " #f)
                                 (cons (if (changes?) "Changes" (file-name (root))) (style-with-bold base)))
                           (if (changes?)
                               (list (cons (string-append " " (number->string (row-count))) (with-class base 'grey)))
                               '())
                           (if (and branch (not (equal? branch "")))
                               (list (cons "  " #f) (cons (string-append (icon-glyph (ui-icon 'git-branch)) " " branch)
                                                          (with-class base 'grey)))
                               '()))
                   base))

(define (draw-row! frame x y width r selected? active? unsaved? base selected-style)
  (define path (row-path r))
  (define status (effective-status path))
  (define dim? (equal? status 'ignored))
  (define row-base (if selected? selected-style base))
  (define icon (if (row-dir? r) (dir-icon (row-name r) (row-open? r)) (file-icon (row-name r))))
  (define name-style
    (let ([s (with-class row-base (cond [dim? 'grey] [else (git-class status)]))])
      (if active? (style-with-bold s) s)))
  (define marker (git-marker status))
  (define right (append (if unsaved? (list (cons (icon-glyph (ui-icon 'unsaved)) (icon-style (ui-icon 'unsaved) row-base))) '())
                        (if marker (list (cons (icon-glyph marker) (icon-style marker row-base))) '())))
  (define right-width (+ (fragments-width right) (if (null? right) 0 1)))
  (define indent (make-string (+ 1 (* 2 (row-depth r))) #\space))
  ;; in changes mode the rows are flat, so the directory follows the name
  (define dir (and (changes?) (not (equal? (parent-path path) (root))) (rel (parent-path path))))
  (when selected? (fill-row! frame x y width row-base))
  (draw-fragments! frame x y (- width right-width)
                   (append (list (cons indent #f)
                                 (cons (icon-glyph icon) (if dim? (with-class row-base 'grey) (icon-style icon row-base)))
                                 (cons " " #f)
                                 (cons (row-name r) name-style))
                           (if dir (list (cons (string-append " " dir) (with-class row-base 'grey))) '()))
                   row-base)
  (unless (null? right)
    (draw-fragments! frame (- (+ x width) right-width) y right-width right row-base)))

(define (render a frame)
  (ensure-rows!)
  (define x (area-x a))
  (define y (area-y a))
  (define w (area-width a))
  (define h (area-height a))
  (define base (theme-scope-ref "ui.background"))
  ;; ui.window is often the background colour itself; indent guides are faint
  ;; but visible in most themes
  (define border-style (let ([guide (theme-scope-ref "ui.virtual.indent-guide")])
                         (if (style->fg guide) guide (theme-scope-ref "ui.window"))))
  (define focused? (host-focused? 'tree))
  (define sel (theme-scope-ref (if focused? "ui.menu.selected" "ui.cursorline.primary")))
  (define selected-style (let ([bg (style->bg sel)]) (if bg (style-bg base bg) sel)))
  (define border-x (if (equal? *side* 'left) (+ x w -1) x))
  (define inner-x (if (equal? *side* 'left) x (+ x 1)))
  (define inner-w (max 0 (- w 1)))
  (buffer/clear-with frame a base)
  (let loop ([row 0])
    (when (< row h)
      (frame-set-string! frame border-x (+ y row) "│" border-style)
      (loop (+ row 1))))
  (draw-header! frame inner-x y inner-w base)
  (set! *list-height* (max 1 (- h 1)))
  (scroll! 0)
  (define active (if (changes?) (diff-shown-path) (focused-path)))
  (define unsaved (unsaved-paths))
  (when (and (changes?) (= (row-count) 0))
    (draw-fragments! frame inner-x (+ y 1) inner-w (list (cons " no changes" (with-class base 'grey))) base))
  (let loop ([i 0])
    (when (< i *list-height*)
      (define r (row-at (+ *scroll* i)))
      (when r
        (draw-row! frame inner-x (+ y 1 i) inner-w r
                   (= (+ *scroll* i) *cursor*)
                   (equal? (row-path r) active)
                   (hash-contains? unsaved (row-path r))
                   base selected-style)
        (loop (+ i 1))))))

;;; setup

(define *enabled?* #f)

(define (tree-enable! #:side [side 'left]
                      #:width [width 30]
                      #:show-hidden [show-hidden #t]
                      #:show-ignored [show-ignored #t])
  (set! *side* side)
  (set! *width* width)
  (set! *show-hidden* show-hidden)
  (set! *show-ignored* show-ignored)
  (unless *enabled?*
    (set! *enabled?* #t)
    (set! *tree* (make-tree (helix-find-workspace)))
    (watch-start!)
    (watch-on-dirs! (lambda (dirs)
                      (for-each (lambda (d) (tree-invalidate! *tree* d)) dirs)
                      (mark-dirty!))))
  (register-part! (make-part 'tree 'pane *side*
                             #:size (lambda () *width*)
                             #:render render
                             #:mouse on-mouse
                             #:key on-key
                             #:on-show tree-reveal-current!)))
