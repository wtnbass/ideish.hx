(define package-name 'ideish)
(define version "0.1.0")
(define dependencies '())
;; native/ builds libideish: filesystem events and git status off the main thread
(define dylibs '((#:name "ideish" #:subdir "native")))
