;; A menu of keys at the bottom right of the editor, drawn like Helix's
;; infobox. A key in it runs its action or opens its submenu; any other key
;; closes it.
;;
;; An item is (list key label action): key a one-character string, action a
;; thunk or a list of items for a submenu.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "../core/host.scm")
(require "../core/text.scm")

(provide show-menu!
         key-event-matches?)

(define *title* "")
(define *items* '())

(define (item-key i) (list-ref i 0))
(define (item-label i) (list-ref i 1))
(define (item-action i) (list-ref i 2))

(define (find-item ch)
  (let loop ([is *items*])
    (cond
      [(null? is) #f]
      [(equal? (item-key (car is)) (string ch)) (car is)]
      [else (loop (cdr is))])))

;; key: a parsed key, (list modifier char) from core/keyspec.scm
(define (key-event-matches? event key)
  (define mod (key-event-modifier event))
  (and (equal? (key-event-char event) (list-ref key 1))
       (cond
         [(equal? (list-ref key 0) 'ctrl) (equal? mod key-modifier-ctrl)]
         [(equal? (list-ref key 0) 'alt) (equal? mod key-modifier-alt)]
         [else (not (or (equal? mod key-modifier-ctrl) (equal? mod key-modifier-alt)))])))

(define (close!) (pop-last-component-by-name! "ideish-menu"))

;; the action runs after the menu is gone, so one that pushes a component or
;; moves the focus is not undone by the close
(define (run! action)
  (close!)
  (enqueue-thread-local-callback
   (lambda ()
     (with-handler (lambda (err) (set-error! (string-append "ideish menu: " (to-string err))))
                   (action)))))

(define (on-event _state event)
  (cond
    [(mouse-event? event)
     (when (equal? (event-mouse-kind event) 0) (close!))
     event-result/consume]
    ;; idle timeouts, pastes and resizes pass through
    [(not (key-event? event)) event-result/ignore]
    [(key-event-escape? event) (close!) event-result/consume]
    [else
     (define mod (key-event-modifier event))
     (define ch (key-event-char event))
     (define item (and ch
                       (not (equal? mod key-modifier-ctrl))
                       (not (equal? mod key-modifier-alt))
                       (find-item ch)))
     (cond
       [(not item) (close!)]
       [(list? (item-action item))
        (set! *title* (item-label item))
        (set! *items* (item-action item))]
       [else (run! (item-action item))])
     event-result/consume]))

(define (draw-border! frame x y width height style)
  (define title (truncate-text (string-append " " *title* " ") (max 0 (- width 2))))
  (define bar (lambda (n) (make-string (max 0 n) #\─)))
  (frame-set-string! frame x y (string-append "┌" title (bar (- width 2 (text-width title))) "┐") style)
  (let loop ([row 1])
    (when (< row (- height 1))
      (frame-set-string! frame x (+ y row) "│" style)
      (frame-set-string! frame (+ x width -1) (+ y row) "│" style)
      (loop (+ row 1))))
  (frame-set-string! frame x (+ y height -1) (string-append "└" (bar (- width 2)) "┘") style))

(define (render _state a frame)
  ;; inside the panes, above the statusline and the command line, as Helix
  ;; places its own
  (define view (or (host-editor-area) a))
  (define key-width (foldl (lambda (i acc) (max acc (text-width (item-key i)))) 0 *items*))
  (define lines (map (lambda (i) (string-append (pad-right (item-key i) key-width) "  " (item-label i)))
                     *items*))
  (define inner (foldl (lambda (l acc) (max acc (text-width l))) (+ 2 (text-width *title*)) lines))
  (define width (min (area-width view) (+ inner 4)))
  (define height (min (max 0 (- (area-height view) 2)) (+ (length lines) 2)))
  (define x (+ (area-x view) (- (area-width view) width)))
  (define y (- (+ (area-y view) (area-height view)) height 2))
  (define style (theme-scope-ref "ui.popup.info"))
  (define text-style (theme-scope-ref "ui.text.info"))
  (when (and (> width 4) (> height 2))
    (buffer/clear-with frame (area x y width height) style)
    (draw-border! frame x y width height style)
    (let loop ([ls lines] [row (+ y 1)])
      (when (and (pair? ls) (< row (+ y height -1)))
        (frame-set-string! frame (+ x 2) row (truncate-text (car ls) (- width 4)) text-style)
        (loop (cdr ls) (+ row 1))))))

(define (show-menu! title items)
  (close!)
  (set! *title* title)
  (set! *items* items)
  (push-component!
   (new-component! "ideish-menu" #f render
                   (hash "handle_event" on-event
                         "cursor" (lambda (_state _area) #f)))))
