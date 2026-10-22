(require "check.scm")
(require "../diff/model.scm")
(require "../diff/query.scm")

;;; parse-diff

(define text
  (string-join
   (list "diff --git a/src/main.rs b/src/main.rs"
         "index 1234567..89abcde 100644"
         "--- a/src/main.rs"
         "+++ b/src/main.rs"
         "@@ -1,4 +1,4 @@ fn main() {"
         " fn main() {"
         "-    println!(\"hi\");"
         "+    println!(\"hello\");"
         "+    run();"
         " }"
         "@@ -20 +21,0 @@"
         "-gone"
         "\\ No newline at end of file"
         "")
   "\n"))
(define rows (parse-diff text))

(check "the hunk header gives both starts and the scope"
       (car rows) (drow 'hunk 1 1 "fn main() {"))
(check "context, deleted and added rows count their own side"
       (cdr (take rows 6))
       (list (drow 'context 1 1 "fn main() {")
             (drow 'del 2 #f "    println!(\"hi\");")
             (drow 'add #f 2 "    println!(\"hello\");")
             (drow 'add #f 3 "    run();")
             (drow 'context 3 4 "}")))
(check "a header without counts starts a hunk too"
       (list-ref rows 6) (drow 'hunk 20 21 ""))
(check "the no-newline marker is not a row" (length rows) 8)
(check "counts added and deleted rows" (diff-counts rows) (cons 2 2))
(check "finds the hunks" (hunk-indices rows) (list 0 6))
(check "a binary file gives a note"
       (parse-diff "diff --git a/x.png b/x.png\nBinary files a/x.png and b/x.png differ\n")
       (list (drow 'note #f #f "Binary files a/x.png and b/x.png differ")))

;;; resolve-inherits

(define queries (hash "ecma" "(identifier) @variable" "base" "; inherits: ecma\n\"if\" @keyword"))
(check "inherited queries replace the comment, recursively"
       (resolve-inherits "; inherits: base\n(x) @y" (lambda (l) (hash-try-get queries l)))
       "(identifier) @variable\n\"if\" @keyword\n(x) @y")
(check "other comments stay"
       (resolve-inherits "; a comment\n(x) @y" (lambda (l) #f))
       "; a comment\n(x) @y")

;;; tag-patterns

(check "each top-level pattern gets its own index"
       (tag-patterns "(identifier) @variable\n\"fn\" @keyword\n[(a) (b)] @x @y")
       "(identifier) @variable._p0\n\"fn\" @keyword._p1\n[(a) (b)] @x._p2 @y._p2")
(check "captures in predicates keep matching their pattern"
       (tag-patterns "((identifier) @f (#eq? @f \"main\"))")
       "((identifier) @f._p0 (#eq? @f._p0 \"main\"))")
(check "@ in strings and comments is left alone"
       (tag-patterns "\"@\" @punct ; @not\n(\"a\\\"@\") @s")
       "\"@\" @punct._p0 ; @not\n(\"a\\\"@\") @s._p1")
(check "split-capture undoes the suffix" (split-capture "keyword.control._p12") (cons "keyword.control" 12))

;;; line-runs

(check "an inner node paints over its parent"
       (line-runs 10 (list (list 0 10 (list 0 -10 0) 'string)
                           (list 3 5 (list 3 -5 0) 'escape)))
       (list (list 0 3 'string) (list 3 5 'escape) (list 5 10 'string)))
(check "on the same node the later pattern wins"
       (line-runs 4 (list (list 0 4 (list 0 -4 7) 'function)
                          (list 0 4 (list 0 -4 2) 'variable)))
       (list (list 0 4 'function)))
(check "uncovered columns are left out"
       (line-runs 6 (list (list 2 4 (list 2 -4 0) 'k)))
       (list (list 2 4 'k)))

(check-summary!)
