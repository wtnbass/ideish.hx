;; Fitting bar content into a fixed width. Pure, so tests run under the steel
;; CLI.

(provide tab-window
         fit-segments)

(define (sum-range widths from to)
  (let loop ([ws widths] [i 0] [acc 0])
    (cond [(or (null? ws) (> i to)) acc]
          [(< i from) (loop (cdr ws) (+ i 1) acc)]
          [else (loop (cdr ws) (+ i 1) (+ acc (car ws)))])))

;; Which tabs to show: (start . end), end exclusive.
;; widths: tab widths, focus: index of the focused tab, first: the start shown
;; last frame, budget: columns available.
;; The window moves only as far as it must to show the focused tab, so tabs do
;; not jump around while switching between visible ones. Left over room is
;; filled to the right, then to the left.
(define (tab-window widths focus first budget)
  (define n (length widths))
  (define (fits? from to) (<= (sum-range widths from to) budget))
  (define start
    (let loop ([s (max 0 (min first focus))])
      (if (and (< s focus) (not (fits? s focus))) (loop (+ s 1)) s)))
  (define end
    (let loop ([e (+ focus 1)])
      (if (and (< e n) (fits? start e)) (loop (+ e 1)) e)))
  (define start*
    (let loop ([s start])
      (if (and (> s 0) (fits? (- s 1) (- end 1))) (loop (- s 1)) s)))
  (cons start* end))

;; Picks which right-hand segments to keep so left and right fit in width.
;; segments: list of (priority . width), in display order. gap: columns
;; between segments. left-min: columns the left side needs at least.
;; Returns the kept segments' indices, dropping the lowest priority first.
(define (fit-segments segments gap left-min width)
  (define (total keep)
    (define ws (map (lambda (i) (cdr (list-ref segments i))) keep))
    (if (null? ws) 0 (+ (apply + ws) (* gap (- (length ws) 1)))))
  (define all (let loop ([i (- (length segments) 1)] [acc '()])
                (if (< i 0) acc (loop (- i 1) (cons i acc)))))
  (let loop ([keep all])
    (if (or (null? keep) (<= (+ left-min gap (total keep)) width))
        keep
        (let* ([lowest (foldl (lambda (i best)
                                (if (or (not best)
                                        (< (car (list-ref segments i)) (car (list-ref segments best))))
                                    i best))
                              #f keep)])
          (loop (filter (lambda (i) (not (= i lowest))) keep))))))
