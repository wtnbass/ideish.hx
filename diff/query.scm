;; Highlight queries read the way Helix reads them, and their captures turned
;; into coloured runs per line. Pure, so tests run under the steel CLI.
;;
;; Helix lets the last matching pattern win when several capture the same
;; node, but a query match groups nodes by capture name and loses the pattern.
;; tag-patterns renames every capture to carry the index of its pattern, so
;; the order can be restored.

(provide resolve-inherits
         tag-patterns
         split-capture
         line-runs)

;; Replaces each "; inherits: a,b" line with the queries of those languages,
;; as Helix does. read: language -> query source or #f
(define (resolve-inherits source read [depth 0])
  (string-join
   (map (lambda (line)
          (define t (trim line))
          (define langs (and (< depth 8) (starts-with? t ";") (inherited-languages t)))
          (if langs
              (string-join (map (lambda (lang)
                                  (let ([s (read lang)]) (if s (resolve-inherits s read (+ depth 1)) "")))
                                langs)
                           "\n")
              line))
        (split-many source "\n"))
   "\n"))

;; "; inherits: ecma,_typescript" -> ("ecma" "_typescript"), or #f
(define (inherited-languages comment)
  (define body (trim (trim-start-matches comment ";")))
  (and (starts-with? body "inherits")
       (let* ([rest (trim (substring body 8 (string-length body)))]
              [rest (trim (trim-start-matches rest ":"))])
         (filter (lambda (s) (not (equal? s "")))
                 (map trim (split-many rest ","))))))

(define (capture-char? c)
  (define n (char->integer c))
  (or (and (>= n 97) (<= n 122)) (and (>= n 65) (<= n 90)) (and (>= n 48) (<= n 57))
      (equal? c #\_) (equal? c #\.) (equal? c #\-)))

;; Renames @name to @name._pN, N counting top-level patterns from 0
(define (tag-patterns source)
  (define cs (list->vector (string->list source)))
  (define n (vector-length cs))
  (define (suffix p) (string->list (string-append "._p" (number->string p))))
  (let loop ([i 0] [depth 0] [pattern -1] [mode 'code] [acc '()])
    (if (>= i n)
        (list->string (reverse acc))
        (let ([c (vector-ref cs i)])
          (cond
            [(equal? mode 'comment)
             (loop (+ i 1) depth pattern (if (equal? c #\newline) 'code 'comment) (cons c acc))]
            [(equal? mode 'string)
             (cond
               [(and (equal? c #\\) (< (+ i 1) n))
                (loop (+ i 2) depth pattern 'string (cons (vector-ref cs (+ i 1)) (cons c acc)))]
               [(equal? c #\") (loop (+ i 1) depth pattern 'code (cons c acc))]
               [else (loop (+ i 1) depth pattern 'string (cons c acc))])]
            [(equal? c #\;) (loop (+ i 1) depth pattern 'comment (cons c acc))]
            [(equal? c #\")
             (loop (+ i 1) depth (if (= depth 0) (+ pattern 1) pattern) 'string (cons c acc))]
            [(or (equal? c #\() (equal? c #\[))
             (loop (+ i 1) (+ depth 1) (if (= depth 0) (+ pattern 1) pattern) 'code (cons c acc))]
            [(or (equal? c #\)) (equal? c #\]))
             (loop (+ i 1) (max 0 (- depth 1)) pattern 'code (cons c acc))]
            [(equal? c #\@)
             (let name ([j (+ i 1)] [acc (cons c acc)])
               (if (and (< j n) (capture-char? (vector-ref cs j)))
                   (name (+ j 1) (cons (vector-ref cs j) acc))
                   (loop j depth pattern 'code (append (reverse (suffix (max 0 pattern))) acc))))]
            [else (loop (+ i 1) depth pattern 'code (cons c acc))])))))

;; "keyword.control._p12" -> ("keyword.control" . 12)
(define (split-capture name)
  (define parts (split-many name "._p"))
  (define n (and (>= (length parts) 2) (string->number (list-ref parts (- (length parts) 1)))))
  (if n
      (cons (string-join (take parts (- (length parts) 1)) "._p") n)
      (cons name 0)))

;; order: (node-start (- node-end) pattern). Painting in ascending order puts
;; inner nodes over outer ones and, on the same node, later patterns over
;; earlier ones.
(define (order<? a b)
  (cond
    [(null? a) #f]
    [(< (car a) (car b)) #t]
    [(> (car a) (car b)) #f]
    [else (order<? (cdr a) (cdr b))]))

;; entries: list of (start end order name), start and end in columns of a line
;; len columns long. Returns runs (start end name), uncovered columns left out.
(define (line-runs len entries)
  (define cells (make-vector len #f))
  (for-each (lambda (e)
              (let fill ([i (max 0 (list-ref e 0))])
                (when (< i (min len (list-ref e 1)))
                  (vector-set! cells i (list-ref e 3))
                  (fill (+ i 1)))))
            (sort entries (lambda (a b) (order<? (list-ref a 2) (list-ref b 2)))))
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i len) (reverse acc)]
      [(not (vector-ref cells i)) (loop (+ i 1) acc)]
      [else
       (let ([name (vector-ref cells i)])
         (let run ([j (+ i 1)])
           (if (and (< j len) (equal? (vector-ref cells j) name))
               (run (+ j 1))
               (loop j (cons (list i j name) acc)))))])))
