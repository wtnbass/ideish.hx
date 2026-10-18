;; Agent pane: a conversation with an ACP agent on the right.
;;
;; The agent runs as a child process owned by the native library, which queues
;; the lines it prints. The shared tick drains them on Helix's main thread and
;; feeds them to the JSON-RPC layer (agent/protocol.scm); session/update
;; notifications build the conversation (agent/session.scm), and
;; agent/layout.scm lays it out as lines.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require (prefix-in helix. "helix/commands.scm"))
(require-builtin helix/core/text as text.)
(require-builtin steel/time)
(require "../core/host.scm")
(require "../core/tick.scm")
(require "../core/text.scm")
(require "../core/watch.scm")
(require "../agent/protocol.scm")
(require "../agent/session.scm")
(require "../agent/layout.scm")
(require "../agent/registry.scm")
(require "../agent/state.scm")

(#%require-dylib "libideish"
                 (only-in agent-spawn agent-send! agent-drain! agent-exit-code agent-kill!))

(provide agent-enable!
         agent-add-selection!
         agent-add-file!
         agent-new-session!
         agent-stop!
         agent-cancel!)

;;; settings

(define *agent* (agent-by-id 'claude))
;; #f, or a list: program and arguments, instead of the agent's own command
(define *command* #f)
(define *width* 64)
(define *log* "/tmp/ideish-agent.log")
(define *follow?* #t)
;; #f, or the mode every session starts in (a value or a name, e.g. "auto");
;; without it a session starts in the mode last picked with Shift-Tab
(define *mode* #f)

;;; state

(define *proc* #f)
(define *rpc* #f)
(define *session* #f)
(define *session-id* #f)
;; 'idle (not started) 'missing 'starting 'ready 'stopped
(define *status* 'idle)
(define *agent-title* (agent-name *agent*))
(define *busy* 0)
(define *turn-start* 0)
;; #f, or hash: 'id 'title 'content 'options 'index
(define *permission* #f)
(define *before* '()) ; input before the cursor, reversed
(define *after* '())
(define *history* '())
(define *history-pos* -1)
;; list of hash: 'label 'block
(define *attachments* '())
(define *scroll* 0)
(define *expand-all?* #f)
(define *cursor-pos* #f)
;; (y . entry) for each transcript row drawn last frame, for clicks
(define *rows* '())
(define *pane-height* 30)

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))
(define (workspace) (helix-find-workspace))
(define (rel path) (relative-path path (workspace)))
(define (busy?) (> *busy* 0))

(define (note! kind text)
  (when *session* (session-push! *session* kind (hash 'text text))))

(define (update-indicator!)
  (set-agent-indicator!
   (cond
     [*permission* (cons (string-append "? " *agent-title* " needs permission") 'red)]
     [(busy?) (cons (string-append "✻ " *agent-title* " working") 'yellow)]
     [else #f])))

;;; process and protocol

(define (send-line line)
  (unless (and *proc* (agent-send! *proc* line))
    (note! 'error "could not write to the agent")))

(define (log-tail)
  (or (safe (lambda ()
              (let* ([port (open-input-file *log*)]
                     [lines (filter (lambda (l) (not (equal? (trim l) "")))
                                    (split-many (read-port-to-string port) "\n"))])
                (close-input-port port)
                (if (null? lines)
                    ""
                    (string-append "\n" (string-join (list-tail lines (max 0 (- (length lines) 3))) "\n"))))))
      ""))

(define (on-exit! code)
  (set! *proc* #f)
  (set! *session-id* #f)
  (set! *status* 'stopped)
  (set! *busy* 0)
  (set! *permission* #f)
  (update-indicator!)
  (note! 'error (string-append "the agent exited (code " (number->string code) ")" (log-tail)
                               "\nlog: " *log*)))

;; tick task: #t while the agent is talking or working
(define (poll)
  (cond
    [(not *proc*) #f]
    [else
     (define lines (agent-drain! *proc*))
     (when lines
       (for-each (lambda (line) (rpc-receive! *rpc* line on-request on-notification)) lines))
     (define code (and *proc* (agent-exit-code *proc*)))
     (when code (on-exit! code))
     (if (or lines (busy?)) #t #f)]))

(define *tick-registered?* #f)

(define (command-line)
  (if *command*
      (cons (car *command*) (cdr *command*))
      (let ([path (agent-locate *agent*)])
        (and path (cons path (agent-args *agent*))))))

(define (start!)
  (unless *proc*
    (unless *session* (set! *session* (make-session (workspace))))
    (define cmd (command-line))
    (cond
      [(not cmd)
       (set! *status* 'missing)
       (note! 'error (string-append (agent-command *agent*) " was not found on PATH. Install it with:\n  "
                                    (agent-install *agent*)))]
      [else
       (set! *status* 'starting)
       (define p (agent-spawn (car cmd) (string-join (cdr cmd) "\n") (workspace) *log*))
       (cond
         [(string? p)
          (set! *status* 'stopped)
          (note! 'error (string-append "could not start the agent: " p))]
         [else
          (set! *proc* p)
          (set! *rpc* (make-rpc send-line))
          (unless *tick-registered?*
            (set! *tick-registered?* #t)
            (tick-register! poll))
          (tick-wake!)
          (initialize!)])])))

(define (initialize!)
  (rpc-request! *rpc* "initialize"
                (hash "protocolVersion" 1
                      "clientCapabilities" (hash "fs" (hash "readTextFile" #f "writeTextFile" #f)
                                                 "terminal" #f)
                      "clientInfo" (hash "name" "ideish" "title" "ideish" "version" "0.1.0"))
                (lambda (result)
                  (define title (jget result 'agentInfo 'title))
                  (when (string? title) (set! *agent-title* title))
                  (new-session!))
                (lambda (err)
                  (set! *status* 'stopped)
                  (note! 'error (string-append "initialize failed: " (to-string (jget err 'message)))))))

;;; the starting mode

(define (state-dir)
  (define state (maybe-get-env-var "XDG_STATE_HOME"))
  (define home (maybe-get-env-var "HOME"))
  (cond [(Ok? state) (string-append (Ok->value state) "/ideish")]
        [(Ok? home) (string-append (Ok->value home) "/.local/state/ideish")]
        [else #f]))

(define (mode-file)
  (define dir (state-dir))
  (and dir (string-append dir "/agent-mode-" (symbol->string (agent-id *agent*)))))

(define (load-mode)
  (define path (mode-file))
  (safe (lambda ()
          (and path (path-exists? path)
               (let* ([port (open-input-file path)]
                      [value (trim (read-port-to-string port))])
                 (close-input-port port)
                 (and (not (equal? value "")) value))))))

(define (save-mode! value)
  (define path (mode-file))
  (when (and path (string? value))
    (safe (lambda ()
            (let ([child (spawn-process (command "mkdir" (list "-p" (state-dir))))])
              (when (Ok? child) (wait (Ok->value child))))
            (let ([port (open-output-file path #:exists 'truncate)])
              (write-string value port)
              (close-output-port port))))))

(define (set-mode! value)
  (define option (session-option-by-category *session* "mode"))
  (when (and option *session-id* (not (equal? value (jget option 'currentValue))))
    (session-set-option-value! *session* (jget option 'id) value)
    (rpc-request! *rpc* "session/set_config_option"
                  (hash "sessionId" *session-id* "configId" (jget option 'id) "value" value)
                  (lambda (result)
                    (let ([options (jget result 'configOptions)])
                      (when (list? options) (set-session-options! *session* options)))))))

;; #:mode wins, then the mode picked last; full-access modes are never applied
(define (apply-starting-mode!)
  (define wanted (or *mode* (load-mode)))
  (define value (and wanted (session-mode-value *session* wanted)))
  (when value (set-mode! value)))

(define (new-session!)
  (session-reset! *session*)
  (set! *session-id* #f)
  (set! *status* 'starting)
  (set! *scroll* 0)
  (rpc-request! *rpc* "session/new"
                (hash "cwd" (workspace) "mcpServers" '())
                (lambda (result)
                  (set! *session-id* (jget result 'sessionId))
                  (let ([options (jget result 'configOptions)])
                    (when (list? options) (set-session-options! *session* options)))
                  (set! *status* 'ready)
                  (apply-starting-mode!))
                (lambda (err)
                  (set! *status* 'stopped)
                  (note! 'error (string-append "could not start a session: " (to-string (jget err 'message))))
                  ;; ACP reserves -32000 for "authentication required"
                  (when (and (number? (jget err 'code)) (= (exact (round (jget err 'code))) -32000))
                    (note! 'info (string-append "log in first: " (agent-login *agent*)))))))

(define (on-request id method params)
  (cond
    [(equal? method "session/request_permission")
     (define tool (jget params 'toolCall))
     (set! *permission* (hash 'id id
                              'title (or (jget tool 'title) "tool")
                              'content (or (jget tool 'content) '())
                              'options (or (jget params 'options) '())
                              'index 0))
     (set! *scroll* 0)
     (update-indicator!)
     ;; the answer is typed in the pane
     (enqueue-thread-local-callback (lambda () (host-focus! 'agent)))]
    [else (rpc-respond-error! *rpc* id -32601 (string-append "method not found: " method))]))

(define (on-notification method params)
  (when (and (equal? method "session/update") *session*)
    (define locs (session-apply-update! *session* (jget params 'update)))
    (when (and *follow?* (pair? locs)) (open-location! (car locs)))))

;;; editor integration

(define (open-location! loc)
  (with-handler
   (lambda (err) (log::warn! (string-append "ideish agent: " (to-string err))))
   (helix.open (car loc))
   (when (cdr loc)
     (helix.goto (number->string (cdr loc)))
     (align_view_center))))

(define (attach! label block)
  (set! *attachments* (append *attachments* (list (hash 'label label 'block block))))
  (host-focus! 'agent))

(define (agent-add-file!)
  (define path (safe cx->current-file))
  (if (not path)
      (set-status! "agent: the buffer has no file")
      (attach! (string-append "@" (rel path))
               (hash "type" "resource_link" "uri" (string-append "file://" path) "name" (rel path)))))

(define (agent-add-selection!)
  (define path (safe cx->current-file))
  (define rope (editor->text (editor->doc-id (editor-focus))))
  (define sel (selection->primary-range (current-selection-object)))
  (define from (range->from sel))
  (define to (range->to sel))
  (define l1 (+ 1 (text.rope-char->line rope from)))
  (define l2 (+ 1 (text.rope-char->line rope (max from (- to 1)))))
  (define name (if path (rel path) "buffer"))
  (define label (string-append "@" name ":" (number->string l1) (if (= l1 l2) "" (string-append "-" (number->string l2)))))
  (attach! label
           (hash "type" "resource"
                 "resource" (hash "uri" (string-append "file://" (or path name) "#L" (number->string l1)
                                                       "-" (number->string l2))
                                  "mimeType" "text/plain"
                                  "text" (text.rope->string (text.rope->slice rope from to))))))

;;; turns

(define (turn-finished!)
  (set! *busy* (max 0 (- *busy* 1)))
  (unless (busy?)
    (set! *permission* #f)
    (watch-refresh-git!)
    (unless (host-focused? 'agent)
      (set-status! (string-append "agent: " *agent-title* " finished"))))
  (update-indicator!))

(define (send-prompt! text)
  (cond
    [(not *session-id*) (set-status! "agent: the session is not ready yet")]
    [else
     (define attachments *attachments*)
     (set! *attachments* '())
     (session-push! *session* 'user (hash 'text text 'attachments (map (lambda (a) (hash-ref a 'label)) attachments)))
     (unless (busy?) (set! *turn-start* (current-milliseconds)))
     (set! *busy* (+ *busy* 1))
     (set! *scroll* 0)
     (update-indicator!)
     (tick-wake!)
     (rpc-request! *rpc* "session/prompt"
                   (hash "sessionId" *session-id*
                         "prompt" (append (map (lambda (a) (hash-ref a 'block)) attachments)
                                          (list (hash "type" "text" "text" text))))
                   (lambda (result)
                     (turn-finished!)
                     (define reason (jget result 'stopReason))
                     (cond
                       [(equal? reason "cancelled") (note! 'info "interrupted")]
                       [(and (string? reason) (not (equal? reason "end_turn")))
                        (note! 'info (string-append "stopped: " reason))]
                       [else void]))
                   (lambda (err)
                     (turn-finished!)
                     (note! 'error (to-string (or (jget err 'message) "the prompt failed")))))]))

(define (answer-permission! option)
  (define id (hash-ref *permission* 'id))
  (set! *permission* #f)
  (update-indicator!)
  (rpc-respond! *rpc* id
                (hash "outcome" (if option
                                    (hash "outcome" "selected" "optionId" (jget option 'optionId))
                                    (hash "outcome" "cancelled")))))

(define (agent-cancel!)
  (when (and *session-id* (busy?))
    (rpc-notify! *rpc* "session/cancel" (hash "sessionId" *session-id*))
    ;; a pending permission is answered as cancelled, as the protocol asks
    (when *permission* (answer-permission! #f))))

(define (agent-new-session!)
  (if *proc* (new-session!) (start!)))

(define (agent-stop!)
  (when *proc*
    (agent-kill! *proc*)
    (set! *proc* #f)
    (set! *session-id* #f)
    (set! *status* 'stopped)
    (set! *busy* 0)
    (set! *permission* #f)
    (update-indicator!)
    (note! 'info "the agent was stopped")))

(define (cycle-mode!)
  (define next (session-next-mode *session*))
  (when next
    (set-mode! next)
    (save-mode! next)))

;;; input

(define (input-string) (list->string (append (reverse *before*) *after*)))

(define (input-set! s)
  (set! *before* (reverse (string->list s)))
  (set! *after* '()))

(define (input-insert! s)
  (set! *before* (append (reverse (string->list s)) *before*)))

(define (input-empty?) (and (null? *before*) (null? *after*)))

(define (delete-word!)
  (let loop ([b *before*] [seen-word? #f])
    (cond
      [(null? b) (set! *before* '())]
      [(char-whitespace? (car b)) (if seen-word? (set! *before* b) (loop (cdr b) #f))]
      [else (loop (cdr b) #t)])))

(define (history-move! delta)
  (define pos (max -1 (min (- (length *history*) 1) (+ *history-pos* delta))))
  (set! *history-pos* pos)
  (input-set! (if (< pos 0) "" (list-ref *history* pos))))

(define (submit!)
  (define text (trim (input-string)))
  (unless (equal? text "")
    (set! *history* (cons text *history*))
    (set! *history-pos* -1)
    (input-set! "")
    (send-prompt! text)))

;;; keys

(define (ctrl? event) (equal? (key-event-modifier event) key-modifier-ctrl))
(define (alt? event) (equal? (key-event-modifier event) key-modifier-alt))
(define (shift? event) (equal? (key-event-modifier event) key-modifier-shift))

(define (permission-key event)
  (define ch (key-event-char event))
  (define opts (hash-ref *permission* 'options))
  (define index (hash-ref *permission* 'index))
  (define (set-index! i) (set! *permission* (hash-insert *permission* 'index i)))
  (cond
    ;; esc rejects, falling back to cancelling
    [(key-event-escape? event)
     (answer-permission! (let loop ([os opts])
                           (cond [(null? os) #f]
                                 [(equal? (jget (car os) 'kind) "reject_once") (car os)]
                                 [else (loop (cdr os))])))]
    [(key-event-enter? event) (answer-permission! (list-ref opts index))]
    [(or (key-event-down? event) (equal? ch #\j)) (set-index! (min (+ index 1) (- (length opts) 1)))]
    [(or (key-event-up? event) (equal? ch #\k)) (set-index! (max 0 (- index 1)))]
    [(and (char? ch) (char-digit? ch))
     (let ([i (- (char->integer ch) (char->integer #\1))])
       (when (and (>= i 0) (< i (length opts))) (answer-permission! (list-ref opts i))))]
    [(and (ctrl? event) (equal? ch #\c)) (agent-cancel!)]
    [else void])
  event-result/consume)

(define (on-key event)
  (define ch (and (key-event? event) (key-event-char event)))
  (cond
    [(paste-event? event) (unless *permission* (input-insert! (paste-event-string event))) event-result/consume]
    [(not (key-event? event)) event-result/consume]
    [*permission* (permission-key event)]
    [(key-event-escape? event) #f]
    [(and (key-event-tab? event) (shift? event)) (cycle-mode!) event-result/consume]
    [(and (key-event-enter? event) (alt? event)) (input-insert! "\n") event-result/consume]
    [(key-event-enter? event) (submit!) event-result/consume]
    [(or (key-event-backspace? event) (and (ctrl? event) (equal? ch #\h)))
     (cond [(pair? *before*) (set! *before* (cdr *before*))]
           [(and (input-empty?) (pair? *attachments*))
            (set! *attachments* (reverse (cdr (reverse *attachments*))))]
           [else void])
     event-result/consume]
    [(ctrl? event)
     (cond
       [(equal? ch #\c) (if (busy?) (agent-cancel!) (input-set! ""))]
       [(equal? ch #\j) (input-insert! "\n")]
       [(equal? ch #\n) (agent-new-session!)]
       [(equal? ch #\t) (set! *expand-all?* (not *expand-all?*))]
       [(equal? ch #\f)
        (set! *follow?* (not *follow?*))
        (set-status! (if *follow?* "agent: follow on" "agent: follow off"))]
       [(equal? ch #\u) (set! *before* '())]
       [(equal? ch #\w) (delete-word!)]
       [(equal? ch #\a) (set! *after* (append (reverse *before*) *after*)) (set! *before* '())]
       [(equal? ch #\e) (set! *before* (append (reverse *after*) *before*)) (set! *after* '())]
       [(equal? ch #\d) (unless (null? *after*) (set! *after* (cdr *after*)))]
       [else void])
     event-result/consume]
    [(key-event-delete? event) (unless (null? *after*) (set! *after* (cdr *after*))) event-result/consume]
    [(key-event-left? event)
     (when (pair? *before*)
       (set! *after* (cons (car *before*) *after*))
       (set! *before* (cdr *before*)))
     event-result/consume]
    [(key-event-right? event)
     (when (pair? *after*)
       (set! *before* (cons (car *after*) *before*))
       (set! *after* (cdr *after*)))
     event-result/consume]
    [(key-event-home? event) (set! *after* (append (reverse *before*) *after*)) (set! *before* '()) event-result/consume]
    [(key-event-end? event) (set! *before* (append (reverse *after*) *before*)) (set! *after* '()) event-result/consume]
    [(key-event-up? event) (unless (string-contains? (input-string) "\n") (history-move! 1)) event-result/consume]
    [(key-event-down? event) (unless (string-contains? (input-string) "\n") (history-move! -1)) event-result/consume]
    [(key-event-page-up? event) (set! *scroll* (+ *scroll* 10)) event-result/consume]
    [(key-event-page-down? event) (set! *scroll* (max 0 (- *scroll* 10))) event-result/consume]
    [(char? ch) (input-insert! (string ch)) event-result/consume]
    [else event-result/consume]))

;;; mouse

(define (on-mouse event a)
  (define kind (event-mouse-kind event))
  (cond
    [(equal? kind 11) (set! *scroll* (+ *scroll* 3))]
    [(equal? kind 10) (set! *scroll* (max 0 (- *scroll* 3)))]
    [(equal? kind 0)
     (define hit (assoc (event-mouse-row event) *rows*))
     (define e (and hit (cdr hit)))
     (define locs (if (and e (equal? (entry-kind e) 'tool))
                      (locations (entry-data e) (workspace))
                      '()))
     (cond
       ;; a tool call opens the file it touched; otherwise the click toggles
       ;; the entry's full output
       [(pair? locs) (open-location! (car locs))]
       [(and e (member (entry-kind e) '(tool thought)))
        (entry-set! e 'expanded (not (entry-get e 'expanded)))]
       [else void])
     (unless (host-focused? 'agent)
       (enqueue-thread-local-callback (lambda () (host-focus! 'agent))))]
    [else void])
  event-result/consume)

;;; drawing

(define (style-of sym)
  (cond
    [(equal? sym 'text) (theme-scope-ref "ui.text")]
    [(equal? sym 'dim) (style-with-dim (theme-scope-ref "ui.text"))]
    [(equal? sym 'bold) (style-with-bold (theme-scope-ref "ui.text"))]
    [(equal? sym 'italic) (style-with-italics (theme-scope-ref "ui.text"))]
    [(equal? sym 'list-mark) (theme-scope-ref "markup.list")]
    [(equal? sym 'link) (theme-scope-ref "markup.link.text")]
    [(equal? sym 'code) (theme-scope-ref "markup.raw")]
    [(equal? sym 'heading) (style-with-bold (theme-scope-ref "markup.heading"))]
    [(equal? sym 'user) (style-with-bold (theme-scope-ref "ui.text"))]
    [(equal? sym 'user-mark) (style-with-bold (theme-scope-ref "keyword"))]
    [(equal? sym 'agent-mark) (theme-scope-ref "ui.text")]
    [(equal? sym 'attachment) (theme-scope-ref "markup.link.url")]
    [(equal? sym 'thought) (style-with-italics (theme-scope-ref "comment"))]
    [(equal? sym 'tool-title) (style-with-bold (theme-scope-ref "ui.text"))]
    [(equal? sym 'ok) (theme-scope-ref "diff.plus")]
    [(equal? sym 'error) (theme-scope-ref "error")]
    [(equal? sym 'running) (theme-scope-ref "warning")]
    [(equal? sym 'pending) (style-with-dim (theme-scope-ref "ui.text"))]
    [(equal? sym 'diff-add) (theme-scope-ref "diff.plus")]
    [(equal? sym 'diff-del) (theme-scope-ref "diff.minus")]
    [(equal? sym 'accent) (theme-scope-ref "keyword")]
    [(equal? sym 'info) (theme-scope-ref "info")]
    [(equal? sym 'warning) (theme-scope-ref "warning")]
    [(equal? sym 'border) (let ([g (theme-scope-ref "ui.virtual.indent-guide")])
                            (if (style->fg g) g (theme-scope-ref "ui.window")))]
    [else (theme-scope-ref "ui.text")]))

;; draws segments from x, at most width columns, on the pane background
(define (draw-segs frame x y segs width bg)
  (let loop ([segs segs] [cx x] [left width])
    (when (and (pair? segs) (> left 0))
      (define text (truncate-text (car (car segs)) left))
      (define style (style-of (cdr (car segs))))
      (frame-set-string! frame cx y text (if bg (style-bg style bg) style))
      (loop (cdr segs) (+ cx (text-width text)) (- left (text-width text))))))

(define (mode-segs)
  (define mode (and *session* (session-option-by-category *session* "mode")))
  (append
   (if mode (list (seg (string-append "⏵⏵ " (session-option-value-name mode)) 'info) (seg "  " 'dim)) '())
   (if *follow?* (list (seg "◉ follow" 'dim)) '())))

(define *spinner* (list "·" "✢" "✳" "✶" "✻" "✽" "✻" "✶" "✳" "✢"))

(define (busy-segs)
  (define elapsed (- (current-milliseconds) *turn-start*))
  (list (seg (string-append (list-ref *spinner* (modulo (quotient elapsed 120) (length *spinner*))) " ") 'running)
        (seg "Working… " 'running)
        (seg (string-append "(" (number->string (quotient elapsed 1000)) "s · ^c to interrupt)") 'dim)))

;; the last `needed` transcript lines as (entry . line), newest entries last
(define (transcript-tail width needed)
  (let loop ([es (if *session* (session-entries *session*) '())] [acc '()] [n 0])
    (if (or (null? es) (>= n needed))
        acc
        (let* ([e (car es)]
               [ls (append (map (lambda (l) (cons e l)) (entry-lines e width *expand-all?* rel))
                           (list (cons #f '())))])
          (loop (cdr es) (append ls acc) (+ n (length ls)))))))

(define (welcome-lines)
  (define (row key text) (list (seg "  " 'dim) (seg key 'accent) (seg (string-append "  " text) 'dim)))
  (list (list (seg (if (equal? *status* 'ready) "Ask anything about this workspace." "Starting the agent…") 'bold))
        '()
        (row "⇧⇥ " "switch mode")
        (row "^n " "new session")
        (row "^t " "show tool output in full")
        (row "^f " "follow the files the agent touches")
        (row "esc" "back to the editor; the pane stays")))

(define (take-last lst n)
  (define len (length lst))
  (if (<= len n) lst (list-tail lst (- len n))))

(define (render a frame)
  (define x0 (area-x a))
  (define y0 (area-y a))
  (define w (area-width a))
  (define h (area-height a))
  (set! *pane-height* h)
  (define bg (theme-scope-ref "ui.background"))
  (buffer/clear-with frame a bg)
  (let loop ([y y0])
    (when (< y (+ y0 h))
      (frame-set-string! frame x0 y "│" (style-of 'border))
      (loop (+ y 1))))
  (define cx (+ x0 2))
  (define cw (max 10 (- w 3)))
  (define rule (list (seg (make-string cw #\─) 'border)))
  (define focused? (host-focused? 'agent))

  ;; header
  (draw-segs frame cx y0
             (list (seg "✻ " 'accent)
                   (seg *agent-title* (if focused? 'heading 'bold))
                   (seg (if (and *session* (session-title *session*))
                            (string-append "  " (session-title *session*)) "")
                        'dim)
                   (seg (cond [(equal? *status* 'starting) "  starting…"]
                              [(equal? *status* 'stopped) "  stopped"]
                              [else ""])
                        'warning))
             cw #f)
  (draw-segs frame cx (+ y0 1) (mode-segs) cw #f)
  (draw-segs frame cx (+ y0 2) rule cw #f)
  (define body-top (+ y0 3))

  ;; footer, bottom up
  (define bottom (+ y0 h -1))
  (draw-segs frame cx bottom
             (list (seg (if *permission* "↑↓ select · enter confirm · esc reject" "esc editor · ⇧⇥ mode · ^n new · ^c interrupt") 'dim))
             cw #f)
  (define footer-top
    (if *permission*
        (let* ([ls (permission-lines *permission* cw (max 6 (- (quotient h 2) 6)) rel)]
               [top (- bottom (length ls))])
          (draw-segs frame cx (- top 1) rule cw #f)
          (let loop ([ls ls] [y top])
            (when (pair? ls)
              (draw-segs frame cx y (car ls) cw #f)
              (loop (cdr ls) (+ y 1))))
          (set! *cursor-pos* #f)
          (- top 1))
        (let* ([all-rows (wrap-chars (append (reverse *before*) *after*) (- cw 2))]
               [rows (take-last all-rows 6)]
               [hidden (- (length all-rows) (length rows))]
               [before-rows (wrap-chars (reverse *before*) (- cw 2))]
               [cursor-row (- (length before-rows) 1 hidden)]
               [cursor-col (text-width (last before-rows))]
               [input-top (- bottom 1 (length rows))])
          (draw-segs frame cx (- bottom 1) rule cw #f)
          (if (input-empty?)
              (draw-segs frame cx input-top (list (seg "❯ " 'user-mark) (seg "Message the agent…" 'dim)) cw #f)
              (let loop ([rs rows] [y input-top] [first? (= hidden 0)])
                (when (pair? rs)
                  (draw-segs frame cx y (list (seg (if first? "❯ " "  ") 'user-mark) (seg (car rs) 'text)) cw #f)
                  (loop (cdr rs) (+ y 1) #f))))
          (set! *cursor-pos* (position (+ input-top (max 0 cursor-row)) (+ cx 2 cursor-col)))
          (define top
            (if (null? *attachments*)
                input-top
                (begin
                  (draw-segs frame cx (- input-top 1)
                             (cons (seg "+ " 'dim)
                                   (map (lambda (at) (seg (string-append (hash-ref at 'label) " ") 'attachment))
                                        *attachments*))
                             cw #f)
                  (- input-top 1))))
          (draw-segs frame cx (- top 1) rule cw #f)
          (- top 1))))

  ;; transcript
  (define busy-row (if (busy?) 1 0))
  (define body-h (max 0 (- footer-top body-top busy-row)))
  (define lines (transcript-tail cw (+ body-h *scroll* 1)))
  (set! *scroll* (min *scroll* (max 0 (- (length lines) body-h))))
  (define visible (take-last (take lines (- (length lines) *scroll*)) body-h))
  (set! *rows* '())
  (let loop ([ls visible] [y body-top])
    (when (pair? ls)
      (draw-segs frame cx y (cdr (car ls)) cw #f)
      (when (car (car ls)) (set! *rows* (cons (cons y (car (car ls))) *rows*)))
      (loop (cdr ls) (+ y 1))))
  (when (and (null? visible) (> body-h 10))
    (let loop ([ls (welcome-lines)] [y (+ body-top 1)])
      (when (pair? ls)
        (draw-segs frame cx y (car ls) cw #f)
        (loop (cdr ls) (+ y 1)))))
  (when (busy?)
    (draw-segs frame cx (+ body-top (length visible)) (busy-segs) cw #f))
  (when (> *scroll* 0)
    (draw-segs frame (+ x0 w -12) body-top (list (seg (string-append "↑ " (number->string *scroll*) " more") 'dim)) 11 #f)))

(define (cursor)
  (and (not *permission*) *cursor-pos*))

;;; setup

(define *enabled?* #f)

;; command: #f, or a list of strings to start instead of the agent's own command
;; mode: #f, or the mode every session starts in
(define (agent-enable! #:width [width 64] #:command [command #f] #:mode [mode #f])
  (set! *width* width)
  (set! *command* command)
  (set! *mode* mode)
  (unless *enabled?*
    (set! *enabled?* #t)
    (watch-start!)
    (register-part! (make-part 'agent 'pane 'right
                               #:size (lambda () *width*)
                               #:render render
                               #:mouse on-mouse
                               #:key on-key
                               #:cursor cursor
                               #:on-show start!))))
