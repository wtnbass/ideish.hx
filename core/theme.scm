;; Colours from the active Helix theme.
;;
;; Icons carry a colour class instead of a fixed colour. Each class maps to a
;; theme scope whose foreground usually has that hue, so icons follow the theme.
;; The icon's upstream hex is the fallback when the theme leaves the scope out.

(require "helix/components.scm")
(require "../icons/icons.scm")

(provide theme-refresh!
         class-color
         icon-style
         scope-style
         scope-fg
         hex->color
         set-class-scopes!)

(define *class-scopes*
  (hash 'red "error"
        'orange "constant.numeric"
        'yellow "warning"
        'green "diff.plus"
        'cyan "hint"
        'blue "function"
        'purple "keyword"
        'magenta "constant.character.escape"
        'grey "comment"))

;; overrides: hash of class -> scope name
(define (set-class-scopes! overrides)
  (set! *class-scopes*
        (foldl (lambda (k acc) (hash-insert acc k (hash-ref overrides k)))
               *class-scopes*
               (hash-keys->list overrides))))

(define (hex-byte hex start)
  (string->number (substring hex start (+ start 2)) 16))

(define (hex->color hex)
  (Color/rgb (hex-byte hex 1) (hex-byte hex 3) (hex-byte hex 5)))

;; class -> Color or #f, rebuilt once per frame by theme-refresh!
(define *palette* (hash))

(define (theme-refresh!)
  (set! *palette*
        (foldl (lambda (class acc)
                 (define fg (style->fg (theme-scope-ref (hash-ref *class-scopes* class))))
                 (if fg (hash-insert acc class fg) acc))
               (hash)
               (hash-keys->list *class-scopes*))))

(define (class-color class [fallback-hex #f])
  (or (hash-try-get *palette* class)
      (and fallback-hex (hex->color fallback-hex))))

;; base with the icon's colour as foreground
(define (icon-style icon base)
  (define color (class-color (icon-class icon) (icon-hex icon)))
  (if color (style-fg base color) base))

(define (scope-style scope) (theme-scope-ref scope))

(define (scope-fg scope) (style->fg (theme-scope-ref scope)))
