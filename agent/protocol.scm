;; JSON-RPC 2.0 over newline-delimited JSON, as ACP uses it.
;; Pure: the caller passes the function that writes a line, and feeds back the
;; lines the agent prints, so tests run without a process.

(provide make-rpc
         rpc-request!
         rpc-notify!
         rpc-respond!
         rpc-respond-error!
         rpc-receive!
         rpc-pending-count
         jget)

;; send: string -> any. handlers: id -> (on-result . on-error)
(struct rpc (send next-id handlers) #:mutable)

(define (make-rpc send) (rpc send 0 (hash)))

;; Nested lookup in parsed JSON: (jget msg 'params 'update) -> value or #f.
;; Parsed objects have symbol keys.
(define (jget v . keys)
  (let loop ([v v] [ks keys])
    (cond
      [(null? ks) v]
      [(hash? v) (loop (hash-try-get v (car ks)) (cdr ks))]
      [else #f])))

(define (write! r msg)
  ((rpc-send r) (value->jsexpr-string msg)))

;; on-error: #f or (error-object) -> any. Returns the request id.
(define (rpc-request! r method params on-result [on-error #f])
  (set-rpc-next-id! r (+ (rpc-next-id r) 1))
  ;; string ids: parsed JSON numbers come back as floats, so an integer id
  ;; would never match its response
  (define id (string-append "h-" (number->string (rpc-next-id r))))
  (set-rpc-handlers! r (hash-insert (rpc-handlers r) id (cons on-result on-error)))
  (write! r (hash "jsonrpc" "2.0" "id" id "method" method "params" params))
  id)

(define (rpc-notify! r method params)
  (write! r (hash "jsonrpc" "2.0" "method" method "params" params)))

(define (rpc-respond! r id result)
  (write! r (hash "jsonrpc" "2.0" "id" id "result" result)))

(define (rpc-respond-error! r id code message)
  (write! r (hash "jsonrpc" "2.0" "id" id "error" (hash "code" code "message" message))))

(define (rpc-pending-count r) (hash-length (rpc-handlers r)))

;; Dispatches one line the agent printed.
;; on-request: (id method params) -> any, on-notification: (method params) -> any
;; Returns #f for a line that is not JSON (agents may log to stdout).
(define (rpc-receive! r line on-request on-notification)
  (define msg (with-handler (lambda (_) #f) (string->jsexpr line)))
  (cond
    [(not (hash? msg)) #f]
    [else
     (define method (jget msg 'method))
     (define id (jget msg 'id))
     (cond
       [(and method id) (on-request id method (jget msg 'params))]
       [method (on-notification method (jget msg 'params))]
       [id
        (define handler (hash-try-get (rpc-handlers r) id))
        (set-rpc-handlers! r (hash-remove (rpc-handlers r) id))
        (define err (jget msg 'error))
        (cond
          [(not handler) void]
          [(hash? err) (when (cdr handler) ((cdr handler) err))]
          [else ((car handler) (jget msg 'result))])]
       [else void])
     #t]))
