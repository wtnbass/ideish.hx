;; Breadcrumb bar: the file's path and the scopes around the cursor, on the
;; top row below the bufferline.
;;
;; Every frame walks up the syntax tree from the cursor (breadcrumb/scopes.scm)
;; through each language layer at the cursor, so an edit shows as soon as Helix
;; has parsed it.

(require "helix/components.scm")
(require "helix/misc.scm")
(require "helix/editor.scm")
(require "helix/static.scm")
(require "helix/treesitter.scm")
(require-builtin helix/core/text as text.)
(require "../core/host.scm")
(require "../core/theme.scm")
(require "../core/draw.scm")
(require "../core/text.scm")
(require "../icons/icons.scm")
(require "../breadcrumb/scopes.scm")
(require "../breadcrumb/languages.scm")

(provide breadcrumb-enable!)

(define *separator* " › ")
(define *name-width* 40)

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

;;; reading the syntax tree

;; rope-len-bytes returns the length in characters, so convert the char length
(define (byte-length rope) (text.rope-char->byte rope (text.rope-len-chars rope)))

;; Node offsets may lag behind the text by a parse; clamp them and slice by
;; characters, since a byte slice inside a character panics in Rust
(define (node-text rope node)
  (define len (byte-length rope))
  (define from (text.rope-byte->char rope (min (tsnode-start-byte node) len)))
  (define to (text.rope-byte->char rope (min (tsnode-end-byte node) len)))
  (if (>= from to) "" (text.rope->string (text.rope->slice rope from to))))

(define (tree-nav rope)
  (nav tsnode-kind tsnode-named-children tsnode-parent
       (lambda (node) (node-text rope node))
       tsnode-start-byte tsnode-end-byte))

;; scopes of every language layer at byte, outermost first
(define (document-scopes doc byte)
  (define rope (editor->text doc))
  (define n (tree-nav rope))
  (define layers (or (safe (lambda () (document->layers-byte-range doc byte (+ byte 1)))) '()))
  (define found
    (foldl (lambda (tree acc)
             (define rules (language-rules (tstree->language tree)))
             (define node (and (pair? rules) (tsnode-named-descendant-byte-range (tstree->root tree) byte byte)))
             (append acc (if node (scopes-at n rules node) '())))
           '()
           layers))
  (sort found (lambda (a b) (< (scope-start a) (scope-start b)))))

(define (cursor-byte doc)
  (define rope (editor->text doc))
  (text.rope-char->byte rope (min (cursor-position) (text.rope-len-chars rope))))

;;; drawing

(define (path-fragments path base dim)
  (define parts (split-many (relative-path path (helix-find-workspace)) "/"))
  (define icon (file-icon (file-name path)))
  (append (foldl (lambda (dir acc) (append acc (list (cons dir dim) (cons *separator* dim))))
                 '()
                 (take parts (- (length parts) 1)))
          (list (cons (icon-glyph icon) (icon-style icon base))
                (cons " " #f)
                (cons (file-name path) #f))))

(define (scope-fragments scopes base dim)
  (foldl (lambda (s acc)
           (define icon (kind-icon (scope-kind s)))
           (append acc (list (cons *separator* dim)
                             (cons (icon-glyph icon) (icon-style icon base))
                             (cons " " #f)
                             (cons (truncate-text (scope-name s) *name-width*) #f))))
         '()
         scopes))

;; drops directories from the left, behind an ellipsis, until the bar fits
(define (fit path-frags scope-frags width)
  (let loop ([ps path-frags])
    (define frags (append ps scope-frags))
    (if (or (<= (fragments-width frags) width) (<= (length ps) 3))
        frags
        (loop (cons (cons "…" (cdr (car ps))) (cdddr ps))))))

(define (render a frame)
  (define doc (safe (lambda () (editor->doc-id (editor-focus)))))
  (define x (area-x a))
  (define y (area-y a))
  (define width (area-width a))
  (define base (theme-scope-ref "ui.background"))
  (define dim (let ([c (class-color 'grey)]) (if c (style-fg base c) base)))
  (fill-row! frame x y width base)
  (when doc
    (define path (safe (lambda () (editor-document->path doc))))
    (define scopes (or (safe (lambda () (document-scopes doc (cursor-byte doc)))) '()))
    (draw-fragments! frame (+ x 1) y (- width 1)
                     (fit (if path (path-fragments path base dim) (list (cons "[scratch]" dim)))
                          (scope-fragments scopes base dim)
                          (- width 1))
                     base)))

(define *enabled?* #f)

(define (breadcrumb-enable!)
  (unless *enabled?*
    (set! *enabled?* #t)
    (register-part! (make-part 'breadcrumb 'bar 'top
                               #:size (lambda () 1)
                               #:render render
                               #:order 20))))
