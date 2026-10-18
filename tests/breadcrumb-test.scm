(require "check.scm")
(require "../breadcrumb/scopes.scm")
(require "../breadcrumb/languages.scm")

;; a fake syntax tree
(struct fnode (kind text start end children parent) #:mutable)

(define (t kind text start end . children)
  (define node (fnode kind text start end children #f))
  (for-each (lambda (c) (set-fnode-parent! c node)) children)
  node)

(define fake (nav fnode-kind fnode-children fnode-parent fnode-text fnode-start fnode-end))
(define (names scopes) (map scope-name scopes))

;; mod outer { impl Foo { fn bar() { let x = 1; } } }
(define let-x (t "let_declaration" "let x = 1;" 40 50 (t "identifier" "x" 44 45)))
(define rust-tree
  (t "source_file" "" 0 100
     (t "mod_item" "" 0 99
        (t "identifier" "outer" 4 9)
        (t "declaration_list" "" 10 98
           (t "impl_item" "" 12 97
              (t "type_identifier" "Foo" 17 20)
              (t "declaration_list" "" 21 96
                 (t "function_item" "" 23 95
                    (t "identifier" "bar" 26 29)
                    (t "block" "" 32 94 let-x))))))))
(define rust-scopes (scopes-at fake (language-rules "rust") let-x))
(check "rust: scopes outermost first" (names rust-scopes) (list "outer" "Foo" "bar"))
(check "rust: scope kinds" (map scope-kind rust-scopes) (list 'module 'class 'function))
(check "rust: a scope spans its node" (list (scope-start (caddr rust-scopes)) (scope-end (caddr rust-scopes))) (list 23 95))

;; const f = () => { ... } names the arrow function
(define body (t "statement_block" "" 16 30))
(t "program" "" 0 40
   (t "lexical_declaration" "" 0 31
      (t "variable_declarator" "" 6 30
         (t "identifier" "f" 6 7)
         (t "arrow_function" "" 10 30 body))))
(check "javascript: a variable holding a function" (names (scopes-at fake (language-rules "typescript") body)) (list "f"))

;; const n = 1 is not a scope
(define plain (t "number" "1" 10 11))
(t "variable_declarator" "" 6 11 (t "identifier" "n" 6 7) plain)
(check "javascript: a plain variable is not a scope" (scopes-at fake (language-rules "javascript") plain) '())

;; (define (outer x) (define (inner z) z)) and (define y 1)
(define inner-body (t "symbol" "z" 30 31))
(t "program" "" 0 50
   (t "list" "" 0 49
      (t "symbol" "define" 1 7)
      (t "list" "" 8 17 (t "symbol" "outer" 9 14) (t "symbol" "x" 15 16))
      (t "list" "" 18 48
         (t "symbol" "define" 19 25)
         (t "list" "" 26 33 (t "symbol" "inner" 27 32))
         inner-body)))
(check "scheme: nested defines" (names (scopes-at fake (language-rules "scheme") inner-body)) (list "outer" "inner"))
(define value (t "number" "1" 11 12))
(t "list" "" 0 13 (t "symbol" "define" 1 7) (t "symbol" "y" 8 9) value)
(check "scheme: a value definition" (names (scopes-at fake (language-rules "scheme") value)) (list "y"))
(define call-arg (t "number" "1" 5 6))
(t "list" "" 0 7 (t "symbol" "display" 1 8) call-arg)
(check "scheme: other lists are not scopes" (scopes-at fake (language-rules "scheme") call-arg) '())

;; # Title / ## Section with nested sections
(define text (t "paragraph" "text" 30 34))
(t "document" "" 0 40
   (t "section" "" 0 40
      (t "atx_heading" "# Title" 0 7 (t "atx_h1_marker" "#" 0 1) (t "inline" "Title" 2 7))
      (t "section" "" 9 40
         (t "atx_heading" "## 日本語の見出し" 9 25 (t "inline" "日本語の見出し" 12 25))
         text)))
(check "markdown: headings of enclosing sections" (names (scopes-at fake (language-rules "markdown") text)) (list "Title" "日本語の見出し"))

(define json-value (t "number" "1" 20 21))
(t "pair" "" 2 22 (t "string" "\"outer\"" 2 9)
   (t "object" "" 11 22 (t "pair" "" 12 21 (t "string" "\"inner\"" 12 19) json-value)))
(check "json: keys without quotes" (names (scopes-at fake (language-rules "json") json-value)) (list "outer" "inner"))

(check "an unknown language has no rules" (language-rules "brainfuck") '())
(check "first-line keeps the first line, trimmed" (first-line "  impl Foo\n  for Bar") "impl Foo")
(check-summary!)
