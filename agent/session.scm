;; Conversation state built from ACP messages.
;; Pure: tests feed parsed JSON and read the entries back.
;;
;; Entries are kept newest first, so streaming chunks and drawing the latest
;; lines touch only the head of the list. Each entry has a revision that the
;; layout cache keys on.

(require "protocol.scm")

(provide make-session
         session-reset!
         session-entries
         session-push!
         session-apply-update!
         session-options
         set-session-options!
         session-option-by-category
         session-option-value-name
         session-set-option-value!
         session-next-mode
         session-mode-value
         full-access-mode?
         session-title
         entry
         entry?
         entry-kind
         entry-data
         entry-rev
         entry-get
         entry-set!
         locations)

(struct entry (kind data rev) #:mutable)

(define (entry-get e key) (hash-try-get (entry-data e) key))

(define (entry-set! e key value)
  (set-entry-data! e (hash-insert (entry-data e) key value))
  (set-entry-rev! e (+ (entry-rev e) 1)))

;; entries: newest first. tools: toolCallId -> entry. cwd: workspace root, to
;; keep follow-along inside it
(struct session (entries tools options title cwd) #:mutable)

(define (make-session cwd) (session '() (hash) '() #f cwd))

(define (session-reset! s)
  (set-session-entries! s '())
  (set-session-tools! s (hash))
  (set-session-title! s #f))

(define (session-push! s kind data)
  (define e (entry kind data 0))
  (set-session-entries! s (cons e (session-entries s)))
  e)

;; Streaming text joins the newest entry when it is of the same kind
(define (append-chunk! s kind text)
  (define head (and (pair? (session-entries s)) (car (session-entries s))))
  (if (and head (equal? (entry-kind head) kind))
      (entry-set! head 'text (string-append (or (entry-get head 'text) "") text))
      (session-push! s kind (hash 'text text))))

;; tool_call.locations -> list of (path . line-or-#f) inside the workspace
(define (locations u cwd)
  (define locs (jget u 'locations))
  (if (list? locs)
      (filter (lambda (l) l)
              (map (lambda (loc)
                     (define path (jget loc 'path))
                     (define line (jget loc 'line))
                     (and (string? path)
                          (starts-with? path (string-append cwd "/"))
                          (cons path (and (number? line) (max 1 (exact (round line)))))))
                   locs))
      '()))

;; ACP replaces a field when an update carries it
(define (merge-tool! e u)
  (for-each (lambda (key)
              (define v (hash-try-get u key))
              (when (and v (not (void? v))) (entry-set! e key v)))
            '(title status kind content locations rawInput)))

(define (tool-call! s u)
  (define e (session-push! s 'tool (hash 'status "pending")))
  (merge-tool! e u)
  (set-session-tools! s (hash-insert (session-tools s) (jget u 'toolCallId) e))
  e)

;;; config options (mode, model, effort, ...)

(define (session-option-by-category s category)
  (let loop ([os (session-options s)])
    (cond
      [(null? os) #f]
      [(equal? (jget (car os) 'category) category) (car os)]
      [else (loop (cdr os))])))

(define (option-values option) (or (jget option 'options) '()))

(define (session-option-value-name option)
  (define current (jget option 'currentValue))
  (let loop ([vs (option-values option)])
    (cond
      [(null? vs) (to-string current)]
      [(equal? (jget (car vs) 'value) current) (or (jget (car vs) 'name) (to-string current))]
      [else (loop (cdr vs))])))

(define (session-set-option-value! s id value)
  (set-session-options! s (map (lambda (o) (if (equal? (jget o 'id) id) (hash-insert o 'currentValue value) o))
                               (session-options s))))

;; Modes that skip every permission prompt. claude-agent-acp marks them with
;; _meta.kind "full_access" in some versions and not in others, so the known
;; value counts too.
(define (full-access-mode? v)
  (or (equal? (jget v '_meta 'kind) "full_access")
      (equal? (jget v 'value) "bypassPermissions")))

;; The value of the mode whose value or name matches wanted (case-insensitive),
;; or #f when there is none or it is a full-access mode
(define (session-mode-value s wanted)
  (define option (session-option-by-category s "mode"))
  (define key (string-downcase wanted))
  (and option
       (let loop ([vs (option-values option)])
         (cond
           [(null? vs) #f]
           [(and (or (equal? (string-downcase (to-string (jget (car vs) 'value))) key)
                     (equal? (string-downcase (or (jget (car vs) 'name) "")) key))
                 (not (full-access-mode? (car vs))))
            (jget (car vs) 'value)]
           [else (loop (cdr vs))]))))

;; The mode after the current one, skipping full-access modes; #f when the
;; agent has no mode option
(define (session-next-mode s)
  (define option (session-option-by-category s "mode"))
  (define values (and option
                      (filter (lambda (v) (not (full-access-mode? v)))
                              (option-values option))))
  (and values
       (pair? values)
       (let loop ([vs values] [i 0])
         (cond
           [(null? vs) (jget (car values) 'value)]
           [(equal? (jget (car vs) 'value) (jget option 'currentValue))
            (jget (list-ref values (modulo (+ i 1) (length values))) 'value)]
           [else (loop (cdr vs) (+ i 1))]))))

;;; session/update

;; Applies one update. Returns the locations the agent is working on, for
;; follow-along: '() when the update names none.
(define (session-apply-update! s u)
  (define kind (jget u 'sessionUpdate))
  (cond
    [(equal? kind "agent_message_chunk")
     (let ([text (jget u 'content 'text)]) (when (string? text) (append-chunk! s 'agent text)))
     '()]
    [(equal? kind "agent_thought_chunk")
     (let ([text (jget u 'content 'text)]) (when (string? text) (append-chunk! s 'thought text)))
     '()]
    [(equal? kind "user_message_chunk")
     (let ([text (jget u 'content 'text)]) (when (string? text) (append-chunk! s 'user text)))
     '()]
    [(equal? kind "tool_call")
     (tool-call! s u)
     (locations u (session-cwd s))]
    [(equal? kind "tool_call_update")
     (define e (hash-try-get (session-tools s) (jget u 'toolCallId)))
     (if e (merge-tool! e u) (tool-call! s u))
     (locations u (session-cwd s))]
    [(equal? kind "plan")
     (define entries (or (jget u 'entries) '()))
     (define existing (let loop ([es (session-entries s)])
                        (cond [(null? es) #f]
                              [(equal? (entry-kind (car es)) 'plan) (car es)]
                              [else (loop (cdr es))])))
     (if existing
         (entry-set! existing 'entries entries)
         (session-push! s 'plan (hash 'entries entries)))
     '()]
    [(equal? kind "config_option_update")
     (let ([options (jget u 'configOptions)]) (when (list? options) (set-session-options! s options)))
     '()]
    [(equal? kind "current_mode_update")
     (let ([mode (session-option-by-category s "mode")])
       (when mode (session-set-option-value! s (jget mode 'id) (jget u 'currentModeId))))
     '()]
    [(equal? kind "session_info_update")
     (let ([title (jget u 'title)]) (when (string? title) (set-session-title! s title)))
     '()]
    [else '()]))
