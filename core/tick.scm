;; One tick on Helix's main thread, shared by everything that polls Rust.
;;
;; Helix renders a frame after every callback it runs, so an idle tick still
;; costs a frame. The tick runs every 50ms while a task reports activity and
;; slows down step by step to 500ms when none does.

(require "helix/misc.scm")

(provide tick-register!
         tick-wake!)

(define *min-ms* 50)
(define *max-ms* 500)
(define *step-ms* 50)
(define *interval* *min-ms*)
(define *tasks* '())
(define *running?* #f)

(define (run-task task)
  (with-handler (lambda (err) (log::warn! (string-append "ideish tick: " (to-string err))) #f)
                (task)))

(define (tick)
  (define active? (foldl (lambda (task acc) (or (run-task task) acc)) #f *tasks*))
  (set! *interval* (if active? *min-ms* (min *max-ms* (+ *interval* *step-ms*))))
  (enqueue-thread-local-callback-with-delay *interval* tick))

;; task: thunk -> #t when it found something to do, which keeps the tick fast
(define (tick-register! task)
  (set! *tasks* (append *tasks* (list task)))
  (unless *running?*
    (set! *running?* #t)
    (enqueue-thread-local-callback-with-delay *interval* tick)))

;; Expect activity soon (a prompt was sent): poll fast from the next tick on
(define (tick-wake!) (set! *interval* *min-ms*))
