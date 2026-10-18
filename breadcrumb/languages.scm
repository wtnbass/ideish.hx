;; Breadcrumb rules per language, keyed by Helix's language name.
;;
;; Each rule says which syntax node opens a scope and how to name it. Node and
;; field names follow each language's tree-sitter grammar.

(require "scopes.scm")

(provide language-rules)

(define (r node-kind scope-kind namer) (rule node-kind scope-kind namer))

;; a JavaScript variable whose value is a function names that function
(define (function-variable n node)
  (and (named-child n node '("arrow_function" "function_expression" "function"))
       ((named-path '("identifier")) n node)))

;; (define (name args) ...) and (define name value) in Lisps
(define (lisp-definition forms)
  (lambda (n node)
    (define children ((nav-children n) node))
    (and (>= (length children) 2)
         (member ((nav-text n) (car children)) forms)
         (let ([target (cadr children)])
           (if (equal? ((nav-kind n) target) "list")
               (let ([inner ((nav-children n) target)])
                 (and (pair? inner) (first-line ((nav-text n) (car inner)))))
               (first-line ((nav-text n) target)))))))

(define (unquote-key s)
  (if (and (>= (string-length s) 2) (equal? (string-ref s 0) #\"))
      (substring s 1 (- (string-length s) 1))
      s))

(define (key-of kinds)
  (lambda (n node)
    (define name ((named-path kinds) n node))
    (and name (unquote-key name))))

(define rust
  (list (r "mod_item" 'module (named-path '("identifier")))
        (r "impl_item" 'class (named-path '("type_identifier" "generic_type" "scoped_type_identifier")))
        (r "trait_item" 'trait (named-path '("type_identifier")))
        (r "struct_item" 'struct (named-path '("type_identifier")))
        (r "enum_item" 'enum (named-path '("type_identifier")))
        (r "union_item" 'struct (named-path '("type_identifier")))
        (r "function_item" 'function (named-path '("identifier")))
        (r "macro_definition" 'macro (named-path '("identifier")))
        (r "const_item" 'constant (named-path '("identifier")))
        (r "static_item" 'constant (named-path '("identifier")))))

(define python
  (list (r "class_definition" 'class (named-path '("identifier")))
        (r "function_definition" 'function (named-path '("identifier")))))

(define go
  (list (r "function_declaration" 'function (named-path '("identifier")))
        (r "method_declaration" 'method (named-path '("field_identifier")))
        (r "type_spec" 'type (named-path '("type_identifier")))))

(define javascript
  (list (r "class_declaration" 'class (named-path '("identifier" "type_identifier")))
        (r "abstract_class_declaration" 'class (named-path '("type_identifier")))
        (r "interface_declaration" 'interface (named-path '("type_identifier")))
        (r "enum_declaration" 'enum (named-path '("identifier")))
        (r "type_alias_declaration" 'type (named-path '("type_identifier")))
        (r "internal_module" 'namespace (named-path '("identifier" "nested_identifier")))
        (r "function_declaration" 'function (named-path '("identifier")))
        (r "generator_function_declaration" 'function (named-path '("identifier")))
        (r "method_definition" 'method (named-path '("property_identifier" "private_property_identifier")))
        (r "variable_declarator" 'function function-variable)))

(define c-like
  (list (r "namespace_definition" 'namespace (named-path '("namespace_identifier")))
        (r "class_specifier" 'class (named-path '("type_identifier")))
        (r "struct_specifier" 'struct (named-path '("type_identifier")))
        (r "enum_specifier" 'enum (named-path '("type_identifier")))
        (r "function_definition" 'function
           (named-path '("function_declarator")
                       '("identifier" "field_identifier" "qualified_identifier" "destructor_name" "operator_name")))))

(define java
  (list (r "class_declaration" 'class (named-path '("identifier")))
        (r "record_declaration" 'class (named-path '("identifier")))
        (r "interface_declaration" 'interface (named-path '("identifier")))
        (r "enum_declaration" 'enum (named-path '("identifier")))
        (r "constructor_declaration" 'constructor (named-path '("identifier")))
        (r "method_declaration" 'method (named-path '("identifier")))))

(define c-sharp
  (list (r "namespace_declaration" 'namespace (named-path '("identifier" "qualified_name")))
        (r "class_declaration" 'class (named-path '("identifier")))
        (r "struct_declaration" 'struct (named-path '("identifier")))
        (r "interface_declaration" 'interface (named-path '("identifier")))
        (r "enum_declaration" 'enum (named-path '("identifier")))
        (r "method_declaration" 'method (named-path '("identifier")))))

(define ruby
  (list (r "module" 'module (named-path '("constant" "scope_resolution")))
        (r "class" 'class (named-path '("constant" "scope_resolution")))
        (r "method" 'method (named-path '("identifier")))
        (r "singleton_method" 'method (named-path '("identifier")))))

(define lua
  (list (r "function_declaration" 'function
           (named-path '("identifier" "dot_index_expression" "method_index_expression")))))

(define bash
  (list (r "function_definition" 'function (named-path '("word")))))

(define zig
  (list (r "function_declaration" 'function (named-path '("identifier")))))

(define scheme
  (list (r "list" 'function (lisp-definition '("define" "define-syntax" "define-values" "define-record-type")))))

(define markdown
  (list (r "section" 'heading (named-path '("atx_heading" "setext_heading") '("inline" "paragraph")))))

(define toml
  (list (r "table" 'namespace (named-path '("bare_key" "dotted_key" "quoted_key")))
        (r "table_array_element" 'namespace (named-path '("bare_key" "dotted_key" "quoted_key")))))

(define json
  (list (r "pair" 'property (key-of '("string")))))

(define yaml
  (list (r "block_mapping_pair" 'property (named-path '("flow_node")))))

(define *languages*
  (hash "rust" rust
        "python" python
        "go" go
        "javascript" javascript
        "jsx" javascript
        "typescript" javascript
        "tsx" javascript
        "c" c-like
        "cpp" c-like
        "java" java
        "c-sharp" c-sharp
        "ruby" ruby
        "lua" lua
        "bash" bash
        "zig" zig
        "scheme" scheme
        "markdown" markdown
        "toml" toml
        "json" json
        "jsonc" json
        "yaml" yaml))

;; rules for a Helix language name, '() when there are none
(define (language-rules language)
  (or (hash-try-get *languages* language) '()))
