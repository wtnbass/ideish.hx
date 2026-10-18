;; Agents ideish knows how to start, and whether they are installed.
;;
;; An agent is found as a command on PATH, like `hx --health` finds language
;; servers. There is no npx fallback: a global install starts fast and works
;; offline. The ACP registry (github.com/agentclientprotocol/registry) is the
;; reference for keeping this table up to date.

(#%require-dylib "libideish" (only-in path-lookup))

(provide agent-by-id
         agent-id
         agent-name
         agent-command
         agent-args
         agent-install
         agent-login
         agent-locate
         agent-health-lines
         *agents*)

;; command: program on PATH. args: list of strings
;; install: how to install it. login: how to authenticate when it asks
(struct agent (id name command args install login))

(define *agents*
  (list (agent 'claude
               "Claude"
               "claude-agent-acp"
               '()
               "npm install -g @agentclientprotocol/claude-agent-acp"
               "run `claude` in a terminal and use /login")))

(define (agent-by-id id)
  (let loop ([as *agents*])
    (cond [(null? as) #f]
          [(equal? (agent-id (car as)) id) (car as)]
          [else (loop (cdr as))])))

;; full path of the agent's command, or #f
(define (agent-locate a) (path-lookup (agent-command a)))

(define (agent-health-lines)
  (map (lambda (a)
         (define path (agent-locate a))
         (string-append (agent-name a) " (" (agent-command a) "): "
                        (if path path (string-append "not found, install with: " (agent-install a)))))
       *agents*))
