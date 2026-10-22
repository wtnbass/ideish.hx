;; A file's diff as rows to draw, read from `git diff` output.
;; Pure, so tests run under the steel CLI.

(provide parse-diff
         drow
         drow?
         drow-kind
         drow-old
         drow-new
         drow-text
         diff-counts
         hunk-indices)

;; kind: 'hunk (the @@ line, text is the enclosing scope git names), 'context,
;; 'add, 'del, or 'note (a line git prints in place of hunks, e.g. for a binary
;; file). old, new: 1-based line numbers on each side, #f where the row has none.
(struct drow (kind old new text) #:transparent)

;; "-12,7" or "+3" -> 12 or 3
(define (range-start field)
  (string->number (car (split-many (substring field 1 (string-length field)) ","))))

;; "@@ -12,7 +12,9 @@ fn main" -> (12 12 "fn main")
(define (parse-hunk-header line)
  (define parts (split-many line " "))
  (define tail (let ([rest (split-many line "@@")])
                 (if (>= (length rest) 3) (trim (string-join (cddr rest) "@@")) "")))
  (list (range-start (list-ref parts 1)) (range-start (list-ref parts 2)) tail))

(define (rest-of line) (substring line 1 (string-length line)))

(define (parse-diff text)
  (let loop ([lines (split-many text "\n")] [in-hunk? #f] [old 0] [new 0] [acc '()])
    (if (null? lines)
        (reverse acc)
        (let ([line (car lines)])
          (cond
            [(starts-with? line "@@ ")
             (define h (parse-hunk-header line))
             (loop (cdr lines) #t (car h) (cadr h) (cons (drow 'hunk (car h) (cadr h) (caddr h)) acc))]
            [(and in-hunk? (starts-with? line " "))
             (loop (cdr lines) #t (+ old 1) (+ new 1) (cons (drow 'context old new (rest-of line)) acc))]
            [(and in-hunk? (starts-with? line "+"))
             (loop (cdr lines) #t old (+ new 1) (cons (drow 'add #f new (rest-of line)) acc))]
            [(and in-hunk? (starts-with? line "-"))
             (loop (cdr lines) #t (+ old 1) new (cons (drow 'del old #f (rest-of line)) acc))]
            ;; "\ No newline at end of file"
            [(and in-hunk? (starts-with? line "\\")) (loop (cdr lines) #t old new acc)]
            [(starts-with? line "Binary files ")
             (loop (cdr lines) #f old new (cons (drow 'note #f #f line) acc))]
            [else (loop (cdr lines) #f old new acc)])))))

;; (added . deleted)
(define (diff-counts rows)
  (foldl (lambda (r acc)
           (cond
             [(equal? (drow-kind r) 'add) (cons (+ (car acc) 1) (cdr acc))]
             [(equal? (drow-kind r) 'del) (cons (car acc) (+ (cdr acc) 1))]
             [else acc]))
         (cons 0 0)
         rows))

;; indices of the hunk rows, ascending
(define (hunk-indices rows)
  (let loop ([rs rows] [i 0] [acc '()])
    (cond
      [(null? rs) (reverse acc)]
      [(equal? (drow-kind (car rs)) 'hunk) (loop (cdr rs) (+ i 1) (cons i acc))]
      [else (loop (cdr rs) (+ i 1) acc)])))
