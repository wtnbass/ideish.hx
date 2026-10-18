;; Minimal assertions for the steel CLI tests
(provide check check-summary!)

(define *failures* 0)
(define *count* 0)

(define (check name actual expected)
  (set! *count* (+ *count* 1))
  (if (equal? actual expected)
      (displayln "ok   " name)
      (begin
        (set! *failures* (+ *failures* 1))
        (displayln "FAIL " name)
        (displayln "     expected: " expected)
        (displayln "     actual:   " actual))))

(define (check-summary!)
  (displayln *count* " checks, " *failures* " failed")
  (when (> *failures* 0) (error "test failures")))
