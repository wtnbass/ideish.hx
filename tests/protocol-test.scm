(require "check.scm")
(require "../agent/protocol.scm")

(define sent '())
(define r (make-rpc (lambda (line) (set! sent (cons line sent)))))
(define (last-sent) (string->jsexpr (car sent)))

(define got #f)
(define failed #f)
(define id (rpc-request! r "initialize" (hash "protocolVersion" 1)
                         (lambda (result) (set! got result))
                         (lambda (err) (set! failed err))))
(check "a request carries a string id" (jget (last-sent) 'id) id)
(check "a request carries its method" (jget (last-sent) 'method) "initialize")
(check "a request waits for its response" (rpc-pending-count r) 1)

(rpc-receive! r (string-append "{\"jsonrpc\":\"2.0\",\"id\":\"" id "\",\"result\":{\"ok\":true}}")
              (lambda (i m p) void) (lambda (m p) void))
(check "the response reaches its handler" (jget got 'ok) #t)
(check "the handler is dropped after the response" (rpc-pending-count r) 0)

(define id2 (rpc-request! r "session/new" (hash) (lambda (x) void) (lambda (err) (set! failed err))))
(rpc-receive! r (string-append "{\"jsonrpc\":\"2.0\",\"id\":\"" id2 "\",\"error\":{\"code\":-32000,\"message\":\"auth\"}}")
              (lambda (i m p) void) (lambda (m p) void))
(check "an error reaches the error handler" (jget failed 'message) "auth")

(define notified #f)
(rpc-receive! r "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"update\":{\"sessionUpdate\":\"plan\"}}}"
              (lambda (i m p) void)
              (lambda (m p) (set! notified (list m (jget p 'update 'sessionUpdate)))))
(check "a notification is dispatched with its params" notified (list "session/update" "plan"))

(define requested #f)
(rpc-receive! r "{\"jsonrpc\":\"2.0\",\"id\":\"fake-1\",\"method\":\"session/request_permission\",\"params\":{}}"
              (lambda (i m p) (set! requested (list i m)))
              (lambda (m p) void))
(check "a request from the agent keeps its id" requested (list "fake-1" "session/request_permission"))

(rpc-respond! r "fake-1" (hash "outcome" (hash "outcome" "cancelled")))
(check "a response goes back with the same id" (jget (last-sent) 'id) "fake-1")
(check "a response carries its result" (jget (last-sent) 'result 'outcome 'outcome) "cancelled")

(check "a line that is not JSON is ignored" (rpc-receive! r "npm warn something" (lambda (i m p) void) (lambda (m p) void)) #f)
(check "jget returns #f for a missing key" (jget (hash 'a (hash 'b 1)) 'a 'c) #f)
(check-summary!)
