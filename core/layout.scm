;; Screen layout, computed from the terminal size and the visible parts.
;; Pure: no Helix calls, so it runs under the plain steel CLI in tests.
;;
;; Side panes take the full height except the command line row. Bars sit in
;; the centre column between the panes: top bars stack down from row 0, bottom
;; bars stack up from the row above the command line.

(provide spec spec? spec-name spec-kind spec-edge spec-size
         rect rect? rect-x rect-y rect-width rect-height
         layout layout? layout-rects layout-clip
         compute-layout
         layout-rect-of
         rect-contains?
         *min-editor-width*)

;; name: symbol, kind: 'pane or 'bar, edge: 'left 'right 'top 'bottom,
;; size: columns for a pane, rows for a bar
(struct spec (name kind edge size))

(struct rect (x y width height) #:transparent)

;; rects: list of (name . rect), clip: list of left right top bottom
(struct layout (rects clip) #:transparent)

(define *min-editor-width* 20)

(define (sum-sizes specs)
  (foldl (lambda (s acc) (+ acc (spec-size s))) 0 specs))

(define (of-edge specs edge)
  (filter (lambda (s) (equal? (spec-edge s) edge)) specs))

;; Shrinks pane widths, last pane first, so the editor keeps its minimum width
(define (fit-panes panes width)
  (define budget (max 0 (- width *min-editor-width*)))
  (let loop ([remaining (reverse panes)] [acc '()] [overflow (- (sum-sizes panes) budget)])
    (if (null? remaining)
        acc
        (let* ([s (car remaining)]
               [cut (min (spec-size s) (max 0 overflow))]
               [size (- (spec-size s) cut)])
          (loop (cdr remaining)
                (if (> size 0) (cons (spec (spec-name s) 'pane (spec-edge s) size) acc) acc)
                (- overflow cut))))))

;; width, height: terminal size. specs: the visible parts, in registration order.
(define (compute-layout width height specs)
  (define pane-height (max 0 (- height 1)))
  (define panes (fit-panes (filter (lambda (s) (equal? (spec-kind s) 'pane)) specs) width))
  (define bars (filter (lambda (s) (equal? (spec-kind s) 'bar)) specs))
  (define lefts (of-edge panes 'left))
  (define rights (of-edge panes 'right))
  (define left-width (sum-sizes lefts))
  (define right-width (sum-sizes rights))
  (define centre-x left-width)
  (define centre-width (max 0 (- width left-width right-width)))

  (define (place-left ss x)
    (if (null? ss)
        '()
        (cons (cons (spec-name (car ss)) (rect x 0 (spec-size (car ss)) pane-height))
              (place-left (cdr ss) (+ x (spec-size (car ss)))))))

  (define (place-right ss x)
    (if (null? ss)
        '()
        (let ([x (- x (spec-size (car ss)))])
          (cons (cons (spec-name (car ss)) (rect x 0 (spec-size (car ss)) pane-height))
                (place-right (cdr ss) x)))))

  (define (place-top ss y)
    (if (null? ss)
        '()
        (cons (cons (spec-name (car ss)) (rect centre-x y centre-width (spec-size (car ss))))
              (place-top (cdr ss) (+ y (spec-size (car ss)))))))

  ;; the first bottom bar sits right above the command line
  (define (place-bottom ss y)
    (if (null? ss)
        '()
        (let ([y (- y (spec-size (car ss)))])
          (cons (cons (spec-name (car ss)) (rect centre-x y centre-width (spec-size (car ss))))
                (place-bottom (cdr ss) y)))))

  (define tops (of-edge bars 'top))
  (layout (append (place-left lefts 0)
                  (place-right rights width)
                  (place-top tops 0)
                  (place-bottom (of-edge bars 'bottom) (- height 1)))
          (list left-width right-width (sum-sizes tops) 0)))

(define (layout-rect-of l name)
  (define hit (assoc name (layout-rects l)))
  (and hit (cdr hit)))

(define (rect-contains? r x y)
  (and r
       (>= x (rect-x r))
       (< x (+ (rect-x r) (rect-width r)))
       (>= y (rect-y r))
       (< y (+ (rect-y r) (rect-height r)))))
