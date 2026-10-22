;; The one Helix component ideish pushes, and the parts drawn inside it.
;;
;; Parts register here with an edge and a size. Every frame the host computes
;; the layout, sets the editor clip (the only place ideish calls
;; set-editor-clip-*), and has each visible part draw inside its own rect.
;;
;; Focus: a focused part gets keys through a second component pushed on top of
;; the stack. Esc, or a click outside the part, pops it and the editor gets
;; keys again. A centre pane hides the editor, so it is hidden whenever the
;; editor gets the keys back.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "layout.scm")
(require "theme.scm")

(provide make-part
         register-part!
         host-focus!
         host-blur!
         host-focused
         host-focused?
         host-show!
         host-hide!
         host-shown?
         host-rect-of
         host-show-editor!
         host-sync!
         host-request-redraw!)

;; name: symbol, kind: 'pane or 'bar, edge: 'left 'right 'top 'bottom 'centre
;; size: thunk -> columns (pane) or rows (bar); 0 hides the part
;; render: (helix-area frame) -> any
;; mouse: #f or (event helix-area) -> event result
;; key: #f or (event) -> event result, or #f to let the host handle Esc
;; on-show: #f or thunk, run when a hidden pane is shown
;; order: parts on the same edge are placed by ascending order, the top bar
;; with the lowest order on row 0
;; cursor: #f or thunk -> position or #f, where the terminal cursor goes while
;; the part has focus
(struct part (name kind edge size render mouse key on-show order cursor))

(define (make-part name kind edge
                   #:size [size (lambda () 0)]
                   #:render [render (lambda (_area _frame) void)]
                   #:mouse [mouse #f]
                   #:key [key #f]
                   #:on-show [on-show #f]
                   #:order [order 50]
                   #:cursor [cursor #f])
  (part name kind edge size render mouse key on-show order cursor))

(define *parts* '())
;; panes start hidden and are shown on demand; bars are always shown
(define *shown* (hash))
(define *focused* #f)
(define *layout* (layout '() (list 0 0 0 0)))
(define *size* #f) ; (width . height) of the last frame
(define *clip* #f)
(define *installed?* #f)

(define (safe-call label thunk)
  (with-handler (lambda (err) (log::warn! (string-append "ideish " label ": " (to-string err))) #f)
                (thunk)))

(define (find-part name)
  (let loop ([ps *parts*])
    (cond
      [(null? ps) #f]
      [(equal? (part-name (car ps)) name) (car ps)]
      [else (loop (cdr ps))])))

(define (host-shown? name)
  (define p (find-part name))
  (and p (or (equal? (part-kind p) 'bar) (hash-contains? *shown* name))))

;; parts by ascending order, registration order among equal orders
(define (ordered-parts)
  (define orders (sort (foldl (lambda (p acc) (if (member (part-order p) acc) acc (cons (part-order p) acc)))
                              '() *parts*)
                       <))
  (foldl (lambda (o acc) (append acc (filter (lambda (p) (= (part-order p) o)) *parts*)))
         '()
         orders))

(define (part-specs)
  (foldl (lambda (p acc)
           (define size (and (host-shown? (part-name p)) (safe-call "size" (part-size p))))
           (if (and (number? size) (> size 0))
               (cons (spec (part-name p) (part-kind p) (part-edge p) size) acc)
               acc))
         '()
         (reverse (ordered-parts))))

(define (helix-area r) (area (rect-x r) (rect-y r) (rect-width r) (rect-height r)))

(define (host-rect-of name)
  (layout-rect-of *layout* name))

;; #t when the clip changed
(define (relayout!)
  (and *size*
    (set! *layout* (compute-layout (car *size*) (cdr *size*) (part-specs)))
    (let ([clip (layout-clip *layout*)])
      (and (not (equal? clip *clip*))
       (begin
        ;; only the edges that changed, so an edge ideish has nothing on is
        ;; left to whatever else sets it
        (let ([old (or *clip* (list 0 0 0 0))])
          (unless (= (list-ref old 0) (list-ref clip 0)) (set-editor-clip-left! (list-ref clip 0)))
          (unless (= (list-ref old 1) (list-ref clip 1)) (set-editor-clip-right! (list-ref clip 1)))
          (unless (= (list-ref old 2) (list-ref clip 2)) (set-editor-clip-top! (list-ref clip 2)))
          (unless (= (list-ref old 3) (list-ref clip 3)) (set-editor-clip-bottom! (list-ref clip 3))))
        (set! *clip* clip)
        #t)))))

;; Recompute the layout now, e.g. after a part was shown, so the editor does
;; not draw one frame with the old clip
(define (host-sync!)
  (when (relayout!) (host-request-redraw!)))

;; Helix renders after every callback it runs, so an empty one asks for a frame
;; without clearing the screen the way :redraw does
(define (host-request-redraw!)
  (enqueue-thread-local-callback (lambda () void)))

(define (render-root _state rect frame)
  (set! *size* (cons (area-width rect) (area-height rect)))
  (theme-refresh!)
  ;; the editor already drew this frame with the old clip
  (when (relayout!) (host-request-redraw!))
  (for-each (lambda (entry)
              (define p (find-part (car entry)))
              (when p
                (safe-call (symbol->string (part-name p))
                           (lambda () ((part-render p) (helix-area (cdr entry)) frame)))))
            (layout-rects *layout*)))

(define (mouse-target event)
  (define col (event-mouse-col event))
  (define row (event-mouse-row event))
  (let loop ([rs (layout-rects *layout*)])
    (cond
      [(null? rs) #f]
      [(rect-contains? (cdr (car rs)) col row) (car rs)]
      [else (loop (cdr rs))])))

(define (handle-root _state event)
  (if (mouse-event? event)
      (let* ([target (mouse-target event)]
             [p (and target (find-part (car target)))])
        (if (and p (part-mouse p))
            (or (safe-call "mouse" (lambda () ((part-mouse p) event (helix-area (cdr target)))))
                event-result/consume)
            event-result/ignore))
      event-result/ignore))

(define (install!)
  (unless *installed?*
    (set! *installed?* #t)
    (push-component!
     (new-component! "ideish" #f render-root
                     (hash "handle_event" handle-root
                           "cursor" (lambda (_state _area) #f))))))

(define (register-part! p)
  (set! *parts* (append (filter (lambda (q) (not (equal? (part-name q) (part-name p)))) *parts*)
                        (list p)))
  (install!)
  (host-sync!))

;;; focus

(define (host-focused) *focused*)
(define (host-focused? name) (equal? *focused* name))

(define (focus-handle _state event)
  (define p (and *focused* (find-part *focused*)))
  (cond
    [(not p) event-result/close]
    [(mouse-event? event)
     ;; a press outside the focused part hands focus back to the editor
     (define r (host-rect-of *focused*))
     (when (and (equal? (event-mouse-kind event) 0)
                (not (rect-contains? r (event-mouse-col event) (event-mouse-row event))))
       (set! *focused* #f)
       (pop-last-component-by-name! "ideish-focus")
       ;; a click on another pane may focus that one; elsewhere the editor
       ;; takes the keys
       (let* ([target (mouse-target event)]
              [q (and target (find-part (car target)))])
         (unless (and q (equal? (part-kind q) 'pane))
           (host-show-editor!))))
     event-result/ignore]
    [else
     (define result (and (part-key p) (safe-call "key" (lambda () ((part-key p) event)))))
     (cond
       [result result]
       [(and (key-event? event) (key-event-escape? event)) (host-blur!) event-result/consume]
       [else event-result/consume])]))

(define (focus-cursor _state _area)
  (define p (and *focused* (find-part *focused*)))
  (and p (part-cursor p) (safe-call "cursor" (part-cursor p))))

(define (host-show! name)
  (define p (find-part name))
  (when (and p (not (host-shown? name)))
    (set! *shown* (hash-insert *shown* name #t))
    (when (part-on-show p) (safe-call "on-show" (part-on-show p)))
    (host-sync!)))

;; The editor takes the keys: hide the centre panes that cover it
(define (host-show-editor!)
  (for-each (lambda (p)
              (when (equal? (part-edge p) 'centre)
                (set! *shown* (hash-remove *shown* (part-name p)))))
            *parts*)
  (host-sync!))

(define (host-hide! name)
  (when (host-focused? name) (host-blur!))
  (set! *shown* (hash-remove *shown* name))
  (host-sync!))

(define (host-focus! name)
  (when (find-part name)
    (host-show! name)
    (unless (host-focused? name)
      (pop-last-component-by-name! "ideish-focus")
      (set! *focused* name)
      (push-component!
       (new-component! "ideish-focus" #f (lambda (_state _area _frame) void)
                       (hash "handle_event" focus-handle
                             "cursor" focus-cursor))))
    (host-request-redraw!)))

(define (host-blur!)
  (when *focused*
    (set! *focused* #f)
    (pop-last-component-by-name! "ideish-focus")
    (host-show-editor!)
    (host-request-redraw!)))
