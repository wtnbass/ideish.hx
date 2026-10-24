;; dev config: HELIX_STEEL_CONFIG=$PWD/dev hx
;; loads ideish from this checkout; build libideish first with `make install`
(require "../ideish.scm")
(require "helix/keymaps.scm")

(ideish-bufferline!)
(ideish-breadcrumb!)
(ideish-statusline!)
(ideish-tree!)
;; IDEISH_AGENT="node dev/fake-agent.mjs" starts the scripted agent instead
(let ([agent (maybe-get-env-var "IDEISH_AGENT")])
  (if (Ok? agent)
      (ideish-agent! #:command (split-many (Ok->value agent) " "))
      (ideish-agent!)))
(ideish-terminal!)

(keymap (global)
        (normal (space (e ":ideish-focus tree")
                       (E ":ideish-toggle tree"))
                (ret (a ":ideish-toggle agent")
                     (s ":ideish-agent-add-selection")
                     (t ":ideish-toggle terminal"))))
