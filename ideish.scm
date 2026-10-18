;; ideish.hx: a unified UI layer for Steel-enabled Helix.
;;
;; Enable the parts you want from init.scm, in any order:
;;
;;   (require "ideish/ideish.scm")
;;   (ideish-bufferline!)
;;   (ideish-breadcrumb!)
;;   (ideish-statusline!)
;;   (ideish-tree! #:side 'left #:width 30)
;;   (ideish-agent!)
;;
;; and bind the commands in config.toml:
;;
;;   space.e = ":ideish-focus tree"
;;   space.E = ":ideish-toggle tree"
;;   ret.a = ":ideish-toggle agent"

(require "core/host.scm")
(require "core/theme.scm")
(require "core/draw.scm")
(require "ui/statusline.scm")
(require "ui/bufferline.scm")
(require "ui/breadcrumb.scm")
(require "ui/tree.scm")
(require "ui/agent.scm")
(require "ui/notice.scm")
(require "agent/registry.scm")

(provide ideish-statusline!
         ideish-bufferline!
         ideish-breadcrumb!
         ideish-tree!
         ideish-agent!
         ideish-icon-scopes!
         ideish-pill-style!
         ideish-focus
         ideish-toggle
         ideish-close
         ideish-tree-reveal
         ideish-agent-add-selection
         ideish-agent-add-file
         ideish-agent-new
         ideish-agent-stop
         ideish-agent-cancel
         ideish-health)

;;@doc
;; Replace the native statusline with ideish's, in the centre column above
;; the command line.
(define (ideish-statusline!) (statusline-enable!))

;;@doc
;; Show open buffers as tabs on the top row. mode: 'multiple (while two or more
;; buffers are open) or 'always.
(define (ideish-bufferline! #:mode [mode 'multiple]) (bufferline-enable! mode))

;;@doc
;; Show the file path and the scopes around the cursor below the bufferline.
(define (ideish-breadcrumb!) (breadcrumb-enable!))

;;@doc
;; Add the file tree pane. It starts hidden; show it with :ideish-focus tree.
(define (ideish-tree! #:side [side 'left]
                       #:width [width 30]
                       #:show-hidden [show-hidden #t]
                       #:show-ignored [show-ignored #t])
  (tree-enable! #:side side #:width width #:show-hidden show-hidden #:show-ignored show-ignored))

;;@doc
;; Shape of the ends of tabs and the mode label: 'square (default), 'slant or 'round
(define (ideish-pill-style! style) (set-pill-style! style))

;;@doc
;; Override which theme scope gives each icon colour class, e.g.
;; (ideish-icon-scopes! (hash 'cyan "type.builtin"))
(define (ideish-icon-scopes! overrides) (set-class-scopes! overrides))

;;@doc
;; Show a pane and give it the keyboard: :ideish-focus tree
(define (ideish-focus name) (host-focus! (string->symbol name)))

;;@doc
;; Show a pane with focus, or hide it when it is shown: :ideish-toggle tree
(define (ideish-toggle name)
  (define part (string->symbol name))
  (if (host-shown? part) (host-hide! part) (host-focus! part)))

;;@doc
;; Hide a pane: :ideish-close tree
(define (ideish-close name) (host-hide! (string->symbol name)))

;;@doc
;; Focus the tree on the current file.
(define (ideish-tree-reveal)
  (host-focus! 'tree)
  (tree-reveal-current!))

;;@doc
;; Add the agent pane on the right. It starts hidden; :ideish-toggle agent
;; shows it and starts the agent. The agent is found on PATH (see
;; :ideish-health); #:command '("program" "arg" ...) starts something else.
;; A session starts in #:mode (e.g. "auto"), or else in the mode last picked
;; with Shift-Tab.
(define (ideish-agent! #:width [width 64] #:command [command #f] #:mode [mode #f])
  (agent-enable! #:width width #:command command #:mode mode))

;;@doc
;; Attach the selection, with its line range, to the next prompt.
(define (ideish-agent-add-selection) (agent-add-selection!))

;;@doc
;; Attach the current file to the next prompt.
(define (ideish-agent-add-file) (agent-add-file!))

;;@doc
;; Start a new conversation.
(define (ideish-agent-new) (agent-new-session!))

;;@doc
;; Stop the agent process.
(define (ideish-agent-stop) (agent-stop!))

;;@doc
;; Interrupt the running turn.
(define (ideish-agent-cancel) (agent-cancel!))

;;@doc
;; Show which agents are installed: :ideish-health
(define (ideish-health)
  (show-notice! "ideish health" (cons "Agents" (map (lambda (l) (string-append "  " l)) (agent-health-lines)))))
