;; A key written as in a Helix keymap: "p", "C-p" or "A-p".

(provide parse-key)

;; -> (list modifier char), modifier 'ctrl, 'alt or #f; #f for anything else,
;; such as a named key like "ret" or two modifiers
(define (parse-key spec)
  (define (rest) (substring spec 2 (string-length spec)))
  (cond
    [(= (string-length spec) 1) (list #f (string-ref spec 0))]
    [(not (= (string-length spec) 3)) #f]
    [(starts-with? spec "C-") (list 'ctrl (string-ref (rest) 0))]
    [(starts-with? spec "A-") (list 'alt (string-ref (rest) 0))]
    [else #f]))
