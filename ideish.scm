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
;;   (ideish-terminal!)
;;
;; and bind the commands in config.toml:
;;
;;   space.e = ":ideish-focus tree"
;;   space.E = ":ideish-toggle tree"
;;   ret.a = ":ideish-toggle agent"
;;   ret.t = ":ideish-toggle terminal"

(require "core/host.scm")
(require "core/theme.scm")
(require "core/draw.scm")
(require "ui/statusline.scm")
(require "ui/bufferline.scm")
(require "ui/breadcrumb.scm")
(require "ui/tree.scm")
(require "ui/diff.scm")
(require "ui/agent.scm")
(require "ui/terminal.scm")
(require "ui/notice.scm")
(require "agent/registry.scm")

(provide ideish-statusline!
         ideish-bufferline!
         ideish-breadcrumb!
         ideish-tree!
         ideish-agent!
         ideish-terminal!
         ideish-icon-scopes!
         ideish-pill-style!
         ideish-focus
         ideish-toggle
         ideish-close
         ideish-tree-reveal
         ideish-changes
         ideish-diff
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
;; Focus the tree listing the files git reports as changed. Enter shows a
;; file's diff against HEAD over the editor; c in the tree switches back.
(define (ideish-changes) (tree-show-changes!))

;;@doc
;; Show the current file's diff against HEAD over the editor.
(define (ideish-diff) (diff-show-current!))

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
;; Add the terminal pane at the bottom, below the statusline and the message
;; row. It starts hidden; :ideish-toggle terminal shows it and starts $SHELL, or
;; #:command '("program" "arg" ...). #:height counts rows.
;; Every key goes to the shell, Esc too; C-\ gives the keys back to the editor.
(define (ideish-terminal! #:height [height 12] #:command [command #f])
  (terminal-enable! #:height height #:command command))

;;@doc
;; Show which agents are installed and whether the terminal is built: :ideish-health
(define (ideish-health)
  (define (section title lines) (cons title (map (lambda (l) (string-append "  " l)) lines)))
  (show-notice! "ideish health"
                (append (section "Agents" (agent-health-lines))
                        (list "")
                        (section "Terminal" (terminal-health-lines)))))
