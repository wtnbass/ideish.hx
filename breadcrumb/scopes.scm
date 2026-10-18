;; Scopes around the cursor, found by walking up the syntax tree.
;;
;; From the deepest node at the cursor, each ancestor is matched against the
;; language's rules (breadcrumb/languages.scm). A rule maps a node kind to a
;; scope kind and a namer that reads the scope's name from the node's children.
;;
;; Pure: tree access goes through a nav record, so tests walk a fake tree.

(provide nav
         nav-kind
         nav-children
         nav-parent
         nav-text
         nav-start
         nav-end
         rule
         rule-node-kind
         rule-scope-kind
         rule-namer
         scope
         scope?
         scope-kind
         scope-name
         scope-start
         scope-end
         scopes-at
         named-child
         named-path
         first-line)

;; kind: node -> string, children: node -> named child nodes,
;; parent: node -> node or #f, text: node -> string, start / end: node -> byte
(struct nav (kind children parent text start end))

;; node-kind: string. scope-kind: symbol for the icon.
;; namer: (nav node) -> name string, or #f when the node is not a scope
(struct rule (node-kind scope-kind namer))

(struct scope (kind name start end) #:transparent)

(define (find-rule rules kind)
  (let loop ([rs rules])
    (cond [(null? rs) #f]
          [(equal? (rule-node-kind (car rs)) kind) (car rs)]
          [else (loop (cdr rs))])))

;; Scopes enclosing node, outermost first
(define (scopes-at n rules node)
  (let loop ([node node] [acc '()])
    (if (not node)
        acc
        (let* ([r (find-rule rules ((nav-kind n) node))]
               [name (and r ((rule-namer r) n node))])
          (loop ((nav-parent n) node)
                (if (and name (not (equal? name "")))
                    (cons (scope (rule-scope-kind r) name ((nav-start n) node) ((nav-end n) node)) acc)
                    acc))))))

(define (first-line s)
  (trim (car (split-many s "\n"))))

;; The first named child of node whose kind is one of kinds, or #f
(define (named-child n node kinds)
  (let loop ([cs ((nav-children n) node)])
    (cond [(null? cs) #f]
          [(member ((nav-kind n) (car cs)) kinds) (car cs)]
          [else (loop (cdr cs))])))

;; Namer: the text of the child reached by following kind lists, one per level.
;; (named-path '("identifier")) names a node by its identifier child.
(define (named-path . levels)
  (lambda (n node)
    (let loop ([node node] [ls levels])
      (cond
        [(not node) #f]
        [(null? ls) (first-line ((nav-text n) node))]
        [else (loop (named-child n node (car ls)) (cdr ls))]))))
