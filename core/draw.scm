;; Drawing runs of styled text inside a part's rect.
;;
;; A fragment is (text . style), where style #f means the run's base style.
;; Drawing never writes past the given width, so a part cannot spill into its
;; neighbours.

(require "helix/components.scm")
(require "text.scm")

(provide fragments-width
         draw-fragments!
         fill-row!
         pill-fragments
         set-pill-style!)

(define (fragments-width frags)
  (foldl (lambda (f acc) (+ acc (text-width (car f)))) 0 frags))

;; Draws frags from x, at most width columns; returns the x after the last one
(define (draw-fragments! frame x y width frags base)
  (let loop ([fs frags] [cx x] [left width])
    (if (or (null? fs) (<= left 0))
        cx
        (let* ([text (truncate-text (car (car fs)) left)]
               [w (text-width text)])
          (frame-set-string! frame cx y text (or (cdr (car fs)) base))
          (loop (cdr fs) (+ cx w) (- left w))))))

(define (fill-row! frame x y width style)
  (when (> width 0)
    (buffer/clear-with frame (area x y width 1) style)))

;;; pills: tabs and the mode label, a run of text on a coloured background

;; 'square: plain padding, 'slant: cut diagonally, 'round: half circles
(define *pill-style* 'square)

(define (set-pill-style! style) (set! *pill-style* style))

;; body: fragments inside the pill. cap: the background colour as foreground,
;; for the end glyphs. fill: the pill's own style, for square ends.
(define (pill-fragments body cap fill)
  (define ends
    (cond
      [(equal? *pill-style* 'round) (cons (cons "" cap) (cons "" cap))]
      [(equal? *pill-style* 'slant) (cons (cons "" cap) (cons "" cap))]
      [else (cons (cons " " fill) (cons " " fill))]))
  (append (list (car ends)) body (list (cdr ends))))
