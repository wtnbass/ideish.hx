(require "check.scm")
(require "../tree/model.scm")

;; fake filesystem: dir -> list of (name . dir?)
(define fs
  (hash "/w" (list (cons "src" #t) (cons "README.md" #f) (cons ".git" #t) (cons "Cargo.toml" #f) (cons "b" #t))
        "/w/src" (list (cons "main.rs" #f) (cons "lib" #t))
        "/w/src/lib" (list (cons "a.rs" #f))
        "/w/b" '()))
(define reads 0)
(define (list-dir dir)
  (set! reads (+ reads 1))
  (map (lambda (e) (cons (string-append dir "/" (car e)) (cdr e))) (or (hash-try-get fs dir) '())))
(define (skip-dot path name dir?) (starts-with? name "."))
(define (names rows) (map (lambda (r) (string-append (make-string (* 2 (max 0 (row-depth r))) #\space) (row-name r))) rows))

(define t (make-tree "/w"))
(check "root lists directories first, case-insensitive"
       (names (tree-rows t list-dir skip-dot))
       (list "w" "b" "src" "Cargo.toml" "README.md"))

(tree-toggle! t "/w/src")
(check "an opened directory shows its children below it"
       (names (tree-rows t list-dir skip-dot))
       (list "w" "b" "src" "  lib" "  main.rs" "Cargo.toml" "README.md"))

(set! reads 0)
(tree-rows t list-dir skip-dot)
(check "listings are cached" reads 0)

(tree-invalidate! t "/w/src")
(tree-rows t list-dir skip-dot)
(check "invalidating one directory re-reads only that directory" reads 1)

(tree-toggle! t "/w/src")
(check "closing hides the children" (length (tree-rows t list-dir skip-dot)) 5)

(define t2 (make-tree "/w"))
(tree-reveal! t2 "/w/src/lib/a.rs")
(check "reveal opens every ancestor"
       (names (tree-rows t2 list-dir skip-dot))
       (list "w" "b" "src" "  lib" "    a.rs" "  main.rs" "Cargo.toml" "README.md"))
(check "open dirs on screen" (sort (tree-open-dirs t2) string<?) (list "/w" "/w/src" "/w/src/lib"))
(tree-close! t2 "/w/src")
(check "a dir under a closed parent is not on screen" (sort (tree-open-dirs t2) string<?) (list "/w"))
(tree-close! t2 "/w")
(check "the root cannot be closed" (tree-open? t2 "/w") #t)

(check "parent-path" (parent-path "/w/src/lib") "/w/src")
(check "parent-path of a top-level dir" (parent-path "/w") "/")
(check "path-within? matches children" (path-within? "/w/src/a" "/w/src") #t)
(check "path-within? rejects siblings with the same prefix" (path-within? "/w/srcx" "/w/src") #f)

(check "changed-paths keeps the files and drops the directories above them"
       (changed-paths (list (cons "/w/src" 'modified) (cons "/w/src/main.rs" 'modified)
                            (cons "/w/new" 'untracked) (cons "/w/a.txt" 'deleted)
                            (cons "/w/target" 'ignored) (cons "/other/x" 'modified))
                      "/w")
       (list (cons "/w/a.txt" 'deleted) (cons "/w/new" 'untracked) (cons "/w/src/main.rs" 'modified)))

(check-summary!)
