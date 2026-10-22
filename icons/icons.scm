;; Icon lookup: file icons from the generated nvim-web-devicons catalog, plus
;; the hand-picked icons ideish's own parts use. Pure, so tests run under the
;; steel CLI; turning a colour class into a theme colour lives in core/theme.scm.
;;
;; An icon is (list glyph colour-class upstream-hex). The colour class is one of
;; red orange yellow green cyan blue purple magenta grey.

(require "catalog.scm")

(provide file-icon
         dir-icon
         ui-icon
         kind-icon
         icon-glyph
         icon-class
         icon-hex)

(define (icon-glyph icon) (car icon))
(define (icon-class icon) (cadr icon))
(define (icon-hex icon) (caddr icon))

(define (entries->hash entries)
  (foldl (lambda (e acc) (hash-insert acc (car e) (cdr e))) (hash) entries))

(define *by-filename* (entries->hash filename-entries))
(define *by-extension* (entries->hash extension-entries))

(define *default-file* (list "" 'grey "#6d8086"))

;; "archive.tar.gz" tries "tar.gz" before "gz"
(define (extension-icon name)
  (define len (string-length name))
  (let loop ([i 0])
    (cond
      [(>= i len) #f]
      [(and (char=? (string-ref name i) #\.) (> i 0))
       (or (hash-try-get *by-extension* (substring name (+ i 1) len))
           (loop (+ i 1)))]
      [else (loop (+ i 1))])))

(define (file-icon name)
  (define key (string-downcase name))
  (or (hash-try-get *by-filename* key)
      (extension-icon key)
      ;; dotfiles such as ".zshrc" whose whole name is an extension
      (and (> (string-length key) 1)
           (char=? (string-ref key 0) #\.)
           (hash-try-get *by-extension* (substring key 1 (string-length key))))
      *default-file*))

(define *dir-closed* (list "󰉋" 'blue "#7ebae4"))
(define *dir-open* (list "󰝰" 'blue "#7ebae4"))
(define *dir-special*
  (hash ".git" (list "" 'orange "#f54d27")
        ".github" (list "" 'grey "#6d8086")
        "node_modules" (list "" 'green "#8cc84b")))

(define (dir-icon name open?)
  (or (hash-try-get *dir-special* name)
      (if open? *dir-open* *dir-closed*)))

;; Icons for ideish's own UI. Git markers are letters so they read without a
;; legend; the rest follow the Nerd Font names in the comments.
(define *ui*
  (hash 'git-modified (list "M" 'yellow "#e5c07b")
        'git-added (list "A" 'green "#98c379")
        'git-untracked (list "U" 'green "#98c379")
        'git-deleted (list "D" 'red "#e06c75")
        'git-renamed (list "R" 'blue "#61afef")
        'git-conflict (list "!" 'magenta "#c678dd")
        'git-branch (list "" 'purple "#c678dd")      ; nf-dev-git_branch
        'error (list "󰅙" 'red "#e06c75")           ; nf-md-close_circle
        'warning (list "󰀪" 'yellow "#e5c07b")      ; nf-md-alert
        'unsaved (list "●" 'yellow "#e5c07b")        ; black circle
        'changes (list "" 'orange "#d19a66")          ; nf-cod-source_control
        'workspace (list "󰙅" 'blue "#61afef")))    ; nf-md-source_repository

(define (ui-icon key)
  (or (hash-try-get *ui* key) *default-file*))

;; Symbol kinds for the breadcrumb, from the VS Code codicons in Nerd Fonts
(define *kinds*
  (hash
        'module (list "" 'blue "#61afef")
        'namespace (list "" 'blue "#61afef")
        'class (list "" 'orange "#d19a66")
        'struct (list "" 'orange "#d19a66")
        'enum (list "" 'orange "#d19a66")
        'interface (list "" 'cyan "#56b6c2")
        'trait (list "" 'cyan "#56b6c2")
        'type (list "" 'cyan "#56b6c2")
        'function (list "" 'purple "#c678dd")
        'method (list "" 'purple "#c678dd")
        'constructor (list "" 'purple "#c678dd")
        'macro (list "" 'purple "#c678dd")
        'property (list "" 'red "#e06c75")
        'variable (list "" 'green "#98c379")
        'constant (list "" 'orange "#d19a66")
        'heading (list "#" 'blue "#61afef")))

(define *kind-default* (list "" 'grey "#6d8086"))

(define (kind-icon kind)
  (or (hash-try-get *kinds* kind) *kind-default*))
