;; The agent's state for other parts (the statusline), without depending on
;; the agent pane itself.

(provide agent-indicator
         set-agent-indicator!)

;; #f, or (text . colour-class) for the statusline
(define *indicator* #f)

(define (agent-indicator) *indicator*)
(define (set-agent-indicator! value) (set! *indicator* value))
