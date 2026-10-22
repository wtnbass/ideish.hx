;; Syntax colours for text that is not a Helix buffer, such as a file at HEAD.
;;
;; The text is parsed with its language's grammar and queried with the
;; language's highlights.scm, read from Helix's runtime directory the way
;; Helix reads it (diff/query.scm). Only the lines asked for are queried.
;;
;; Helix holds its configuration while it asks for a language's query, so the
;; query cannot be compiled then: a language first asked for is noted, and the
;; lines are queried again once it is compiled.
;;
;; Running a query calls back into Steel for each language's query, and a
;; callback made inside with-handler breaks the VM when the handler returns
;; (a slice index panic). highlight-lines must therefore run outside every
;; with-handler, e.g. from enqueue-thread-local-callback, and catches nothing.

(require "helix/treesitter.scm")
(require "helix/configuration.scm")
(require "helix/editor.scm")
(require-builtin helix/core/text as text.)
(require "query.scm")

(provide language-for-path
         highlight-lines)

(define (safe thunk) (with-handler (lambda (_) #f) (thunk)))

;;; runtime

(define (env name)
  (define v (maybe-get-env-var name))
  (and (Ok? v) (Ok->value v)))

;; searched in Helix's order: the config directory's runtime, then HELIX_RUNTIME
(define (runtime-dirs)
  (define config (or (env "XDG_CONFIG_HOME")
                     (let ([home (env "HOME")]) (and home (string-append home "/.config")))))
  (filter (lambda (d) (and d (path-exists? d)))
          (list (and config (string-append config "/helix/runtime")) (env "HELIX_RUNTIME"))))

(define (read-file path)
  (safe (lambda ()
          (let* ([port (open-input-file path)]
                 [s (read-port-to-string port)])
            (close-input-port port)
            s))))

(define (read-query lang)
  (let loop ([dirs (runtime-dirs)])
    (and (pair? dirs)
         (or (read-file (string-append (car dirs) "/queries/" lang "/highlights.scm"))
             (loop (cdr dirs))))))

;; language -> compiled query, or #f when it has none or it does not compile
(define *queries* (hash))

(define (language-query lang)
  (if (hash-contains? *queries* lang)
      (hash-ref *queries* lang)
      (let* ([source (read-query lang)]
             [query (and source
                         (safe (lambda ()
                                 (string->tsquery lang (tag-patterns (resolve-inherits source read-query))))))])
        (set! *queries* (hash-insert *queries* lang query))
        query)))

;;; languages

;; file name or extension -> language, from the languages that have queries
(define *file-types* #f)

(define (file-types)
  (unless *file-types*
    (set! *file-types*
          (foldl (lambda (dir acc)
                   (foldl (lambda (lang-dir acc)
                            (define lang (file-name lang-dir))
                            (define config (safe (lambda () (get-language-config lang))))
                            (define types (and config (hash-try-get config 'file-types)))
                            (if (list? types)
                                (foldl (lambda (t acc)
                                         (if (and (string? t) (not (hash-contains? acc t))) (hash-insert acc t lang) acc))
                                       acc
                                       types)
                                acc))
                          acc
                          (or (safe (lambda () (read-dir (string-append dir "/queries")))) '())))
                 (hash)
                 (runtime-dirs))))
  *file-types*)

(define (open-language path)
  (let loop ([ids (or (safe editor-all-documents) '())])
    (cond
      [(null? ids) #f]
      [(equal? (safe (lambda () (editor-document->path (car ids)))) path)
       (safe (lambda () (editor-document->language (car ids))))]
      [else (loop (cdr ids))])))

;; The language Helix gives an open buffer, else the one whose file types name
;; the file or its extension
(define (language-for-path path)
  (define name (file-name path))
  (define parts (split-many name "."))
  (or (open-language path)
      (hash-try-get (file-types) name)
      (and (> (length parts) 1) (hash-try-get (file-types) (list-ref parts (- (length parts) 1))))))

;;; highlighting

;; text in lang, lines given as (first . last), 1-based and inclusive.
;; Returns line -> runs (start end scope), in character columns.
(define (highlight-lines text lang ranges)
  (define rope (text.string->rope text))
  (define syntax (and lang (language-query lang) (safe (lambda () (rope->tssyntax rope lang)))))
  (define missing '())
  (define loader
    (tsquery-loader (lambda (l)
                      (if (hash-contains? *queries* l)
                          (hash-ref *queries* l)
                          (begin (set! missing (cons l missing)) #f)))))
  (if syntax
      (let ([lines (highlight rope syntax loader ranges)])
        (if (null? missing)
            lines
            (begin
              (for-each language-query missing)
              (highlight rope syntax loader ranges))))
      (hash)))

(define (highlight rope syntax loader ranges)
  (define line-count (text.rope-len-lines rope))
  (define char-count (text.rope-len-chars rope))
  ;; rope-len-bytes returns the length in characters
  (define byte-count (text.rope-char->byte rope char-count))
  (define (line-char l) (if (>= l line-count) char-count (text.rope-line->char rope l)))
  (define (line-byte l) (if (>= l line-count) byte-count (text.rope-line->byte rope l)))
  (foldl (lambda (range acc)
           (define first (- (car range) 1))
           (define last (- (cdr range) 1))
           (define match (query-tssyntax-byte-range loader syntax rope (line-byte first) (line-byte (+ last 1))))
           ;; line -> entries (start end order scope)
           (define entries
             (foldl (lambda (name acc)
                      (define capture (split-capture name))
                      (define scope (car capture))
                      (if (or (starts-with? scope "_") (starts-with? scope "local"))
                          acc
                          (foldl (lambda (node acc)
                                   (define start-byte (min (tsnode-start-byte node) byte-count))
                                   (define end-byte (min (tsnode-end-byte node) byte-count))
                                   (define start (text.rope-byte->char rope start-byte))
                                   (define end (text.rope-byte->char rope end-byte))
                                   (define order (list start-byte (- end-byte) (cdr capture)))
                                   (let loop ([l (max first (text.rope-char->line rope start))] [acc acc])
                                     (if (or (> l last) (>= (line-char l) end))
                                         acc
                                         (let ([from (line-char l)])
                                           (loop (+ l 1)
                                                 (hash-insert acc l (cons (list (max 0 (- start from)) (- end from) order scope)
                                                                          (or (hash-try-get acc l) '()))))))))
                                 acc
                                 (or (tsmatch-capture match name) '()))))
                    (hash)
                    (tsmatch-captures match)))
           (let loop ([l first] [acc acc])
             (if (> l last)
                 acc
                 (loop (+ l 1)
                       (hash-insert acc (+ l 1)
                                    (line-runs (- (line-char (+ l 1)) (line-char l))
                                               (or (hash-try-get entries l) '())))))))
         (hash)
         ranges))
