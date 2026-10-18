;; A box of text over the editor, closed by any key or click.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "../core/text.scm")

(provide show-notice!)

(define (render title lines _state a frame)
  (define width (min (- (area-width a) 4)
                     (+ 4 (foldl (lambda (l acc) (max acc (text-width l))) (text-width title) lines))))
  (define height (+ 3 (length lines)))
  (define x (+ (area-x a) (quotient (- (area-width a) width) 2)))
  (define y (+ (area-y a) (quotient (- (area-height a) height) 2)))
  (define style (theme-scope-ref "ui.popup"))
  (buffer/clear-with frame (area x y width height) style)
  (frame-set-string! frame (+ x 2) y (truncate-text title (- width 4)) (style-with-bold (theme-scope-ref "ui.text")))
  (let loop ([ls lines] [row (+ y 2)])
    (when (pair? ls)
      (frame-set-string! frame (+ x 2) row (truncate-text (car ls) (- width 4)) (theme-scope-ref "ui.text"))
      (loop (cdr ls) (+ row 1)))))

(define (show-notice! title lines)
  (push-component!
   (new-component! "ideish-notice" #f
                   (lambda (state a frame) (render title lines state a frame))
                   (hash "handle_event"
                         (lambda (_state event)
                           (if (or (key-event? event)
                                   (and (mouse-event? event) (equal? (event-mouse-kind event) 0)))
                               event-result/close
                               event-result/consume))
                         "cursor" (lambda (_state _area) #f)))))
