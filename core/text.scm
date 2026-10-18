;; Terminal text helpers: display width and fitting text into columns.
;; Pure, so tests run under the steel CLI.

(provide char-width
         text-width
         truncate-text
         pad-right
         relative-path)

(define (between? n lo hi) (and (>= n lo) (<= n hi)))

;; East Asian wide and emoji ranges take two columns. Nerd Font glyphs live in
;; the private use areas and take one.
(define (char-width c)
  (define n (char->integer c))
  (cond
    [(< n #x1100) 1]
    [(or (between? n #x1100 #x115F)
         (between? n #x2E80 #x303E)
         (between? n #x3041 #x33FF)
         (between? n #x3400 #x4DBF)
         (between? n #x4E00 #x9FFF)
         (between? n #xA000 #xA4CF)
         (between? n #xAC00 #xD7A3)
         (between? n #xF900 #xFAFF)
         (between? n #xFE30 #xFE4F)
         (between? n #xFF00 #xFF60)
         (between? n #xFFE0 #xFFE6)
         (between? n #x1F300 #x1F64F)
         (between? n #x1F900 #x1F9FF)
         (between? n #x20000 #x3FFFD))
     2]
    [else 1]))

(define (text-width s)
  (foldl (lambda (c acc) (+ acc (char-width c))) 0 (string->list s)))

;; Cuts s to at most width columns, ending in "…" when it had to cut
(define (truncate-text s width)
  (cond
    [(<= width 0) ""]
    [(<= (text-width s) width) s]
    [else
     (let loop ([cs (string->list s)] [used 0] [acc '()])
       (if (null? cs)
           (list->string (reverse acc))
           (let ([w (char-width (car cs))])
             (if (> (+ used w) (- width 1))
                 (string-append (list->string (reverse acc)) "…")
                 (loop (cdr cs) (+ used w) (cons (car cs) acc))))))]))

(define (pad-right s width)
  (define w (text-width s))
  (if (>= w width) s (string-append s (make-string (- width w) #\space))))

;; path below root without the root prefix, or path itself outside root
(define (relative-path path root)
  (define prefix (if (ends-with? root "/") root (string-append root "/")))
  (if (starts-with? path prefix)
      (substring path (string-length prefix) (string-length path))
      path))
