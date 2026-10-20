;; Screen layout, computed from the terminal size and the visible parts.
;; Pure: no Helix calls, so it runs under the plain steel CLI in tests.
;;
;; Side panes take the full height except the command line row. Bars and
;; bottom panes sit in the centre column between the side panes: top bars stack
;; down from row 0 and bottom bars stack up from the row above the command line.
;;
;; A bottom bar is drawn over the statusline row of the editor's last view, so
;; it clips nothing. Bottom panes stack up from the last row, the command line
;; row included, and are clipped. Helix draws its messages on the last row of
;; the clipped area, so they land in the row between the bottom bars and the
;; bottom panes, which nothing draws over; the : prompt still takes the last
;; row while it is open.

(provide spec spec? spec-name spec-kind spec-edge spec-size
         rect rect? rect-x rect-y rect-width rect-height
         layout layout? layout-rects layout-clip
         compute-layout
         layout-rect-of
         rect-contains?
         *min-editor-width*
         *min-editor-height*)

;; name: symbol, kind: 'pane or 'bar, edge: 'left 'right 'top 'bottom,
;; size: columns for a side pane, rows for a bar or a bottom pane
(struct spec (name kind edge size))

(struct rect (x y width height) #:transparent)

;; rects: list of (name . rect), clip: list of left right top bottom
(struct layout (rects clip) #:transparent)

(define *min-editor-width* 20)
(define *min-editor-height* 5)

(define (sum-sizes specs)
  (foldl (lambda (s acc) (+ acc (spec-size s))) 0 specs))

(define (of-edge specs edge)
  (filter (lambda (s) (equal? (spec-edge s) edge)) specs))

;; Shrinks pane sizes, last pane first, so they fit in budget
(define (fit-panes panes budget)
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
  (define all-panes (filter (lambda (s) (equal? (spec-kind s) 'pane)) specs))
  (define panes (fit-panes (filter (lambda (s) (member (spec-edge s) '(left right))) all-panes)
                           (max 0 (- width *min-editor-width*))))
  (define bars (filter (lambda (s) (equal? (spec-kind s) 'bar)) specs))
  (define lefts (of-edge panes 'left))
  (define rights (of-edge panes 'right))
  (define tops (of-edge bars 'top))
  (define bottom-bars (of-edge bars 'bottom))
  (define bottom-bars-height (sum-sizes bottom-bars))
  ;; the bottom bars lie over the editor's rows, so only the message row is extra
  (define bottoms (fit-panes (of-edge all-panes 'bottom)
                             (max 0 (- pane-height (sum-sizes tops) *min-editor-height*))))
  (define bottoms-height (sum-sizes bottoms))
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

  (layout (append (place-left lefts 0)
                  (place-right rights width)
                  (place-top tops 0)
                  (place-bottom bottoms height)
                  (place-bottom bottom-bars (- height 1 bottoms-height)))
          (list left-width right-width (sum-sizes tops) bottoms-height)))

(define (layout-rect-of l name)
  (define hit (assoc name (layout-rects l)))
  (and hit (cdr hit)))

(define (rect-contains? r x y)
  (and r
       (>= x (rect-x r))
       (< x (+ (rect-x r) (rect-width r)))
       (>= y (rect-y r))
       (< y (+ (rect-y r) (rect-height r)))))
