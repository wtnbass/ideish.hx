;; Laying the conversation out as lines for the agent pane.
;; Pure, so tests run under the steel CLI. A line is a list of segments, and a
;; segment is (text . style-symbol); ui/agent.scm turns the symbols into theme
;; styles.

(require "../core/text.scm")
(require "protocol.scm")
(require "session.scm")

(provide seg
         segs-width
         wrap-segs
         inline-segs
         markdown-lines
         plain-lines
         diff-lines
         diff-stat
         entry-lines
         permission-lines
         wrap-chars)

(define (seg text style) (cons text style))

(define (segs-width segs)
  (foldl (lambda (s acc) (+ acc (text-width (car s)))) 0 segs))

(define (take-at-most lst n)
  (if (or (<= n 0) (null? lst)) '() (cons (car lst) (take-at-most (cdr lst) (- n 1)))))

(define (blank? s) (equal? (trim s) ""))

;;; wrapping

;; consecutive cells of one style back into segments
(define (cells->segs cells)
  (let loop ([cells cells] [cur '()] [style #f] [out '()])
    (cond
      [(null? cells)
       (reverse (if (null? cur) out (cons (seg (list->string (reverse cur)) style) out)))]
      [(or (null? cur) (equal? (cdr (car cells)) style))
       (loop (cdr cells) (cons (car (car cells)) cur) (cdr (car cells)) out)]
      [else
       (loop (cdr cells) (list (car (car cells))) (cdr (car cells))
             (cons (seg (list->string (reverse cur)) style) out))])))

;; cells after the last space of a reversed cell list, #f when none is near
(define (last-space-offset rev-cells)
  (let loop ([l rev-cells] [i 0])
    (cond [(or (null? l) (> i 24)) #f]
          [(equal? (car (car l)) #\space) i]
          [else (loop (cdr l) (+ i 1))])))

(define (word-char? ch)
  (and (< (char->integer ch) 128) (not (char-whitespace? ch))))

;; Wraps segments to width; continuation lines start with indent.
;; Latin words move whole; CJK text breaks anywhere.
(define (wrap-segs segs width indent)
  (define indent-w (segs-width indent))
  (define cells
    (apply append (map (lambda (s) (map (lambda (c) (cons c (cdr s))) (string->list (car s)))) segs)))
  (let loop ([cells cells] [cur '()] [w 0] [out '()] [first? #t])
    (define limit (max 4 (if first? width (- width indent-w))))
    (define (emit rev) (if first? (cells->segs (reverse rev)) (append indent (cells->segs (reverse rev)))))
    ;; a broken line does not keep the spaces it ended with
    (define (emit-broken rev)
      (emit (let drop ([r rev]) (if (and (pair? r) (equal? (car (car r)) #\space)) (drop (cdr r)) r))))
    (cond
      [(null? cells) (reverse (cons (emit cur) out))]
      [else
       (define cw (char-width (car (car cells))))
       (if (and (> (+ w cw) limit) (pair? cur))
           (let ([sp (last-space-offset cur)])
             (if (and sp (< sp (- (length cur) 1))
                      (word-char? (car (car cells)))
                      (word-char? (car (car cur))))
                 (loop (append (reverse (take cur sp)) cells) '() 0
                       (cons (emit-broken (list-tail cur (+ sp 1))) out) #f)
                 (loop (if (equal? (car (car cells)) #\space) (cdr cells) cells) '() 0
                       (cons (emit-broken cur) out) #f)))
           (loop (cdr cells) (cons (car cells) cur) (+ w cw) out first?))])))

;;; markdown

(define (find-char cs ch)
  (let loop ([cs cs] [i 0])
    (cond [(null? cs) #f] [(equal? (car cs) ch) i] [else (loop (cdr cs) (+ i 1))])))

;; `code`, **bold**, *italic* / _italic_ and [text](url)
(define (inline-segs text base)
  (define (flush acc style out)
    (if (null? acc) out (cons (seg (list->string (reverse acc)) style) out)))
  (let loop ([cs (string->list text)] [acc '()] [out '()] [bold? #f] [italic? #f])
    (define style (cond [bold? 'bold] [italic? 'italic] [else base]))
    (cond
      [(null? cs) (reverse (flush acc style out))]
      [(and (equal? (car cs) #\`) (find-char (cdr cs) #\`))
       (let ([i (find-char (cdr cs) #\`)])
         (loop (list-tail (cdr cs) (+ i 1)) '()
               (cons (seg (list->string (take (cdr cs) i)) 'code) (flush acc style out))
               bold? italic?))]
      [(and (equal? (car cs) #\*) (pair? (cdr cs)) (equal? (cadr cs) #\*))
       (loop (cddr cs) '() (flush acc style out) (not bold?) italic?)]
      ;; italic only when it opens before a word or closes after one
      [(and (or (equal? (car cs) #\*)
                (and (equal? (car cs) #\_) (or italic? (null? acc) (char-whitespace? (car acc)))))
            (or italic? (and (pair? (cdr cs)) (not (char-whitespace? (cadr cs))) (find-char (cdr cs) (car cs)))))
       (loop (cdr cs) '() (flush acc style out) bold? (not italic?))]
      [(and (equal? (car cs) #\[) (find-char (cdr cs) #\]))
       (let* ([i (find-char (cdr cs) #\])]
              [rest (list-tail (cdr cs) (+ i 1))]
              [close (and (pair? rest) (equal? (car rest) #\() (find-char (cdr rest) #\)))])
         (if close
             (loop (list-tail (cdr rest) (+ close 1)) '()
                   (cons (seg (list->string (take (cdr cs) i)) 'link) (flush acc style out))
                   bold? italic?)
             (loop (cdr cs) (cons (car cs) acc) out bold? italic?)))]
      [else (loop (cdr cs) (cons (car cs) acc) out bold? italic?)])))

(define (heading-level line)
  (let loop ([i 0])
    (if (and (< i (string-length line)) (equal? (string-ref line i) #\#)) (loop (+ i 1)) i)))

;; "12. item" -> length of the "12. " marker, or #f
(define (numbered-item trimmed)
  (let loop ([i 0])
    (cond
      [(and (< i (string-length trimmed)) (char-digit? (string-ref trimmed i))) (loop (+ i 1))]
      [(and (> i 0) (< (+ i 1) (string-length trimmed))
            (equal? (string-ref trimmed i) #\.) (equal? (string-ref trimmed (+ i 1)) #\space))
       (+ i 2)]
      [else #f])))

(define (leading-spaces line)
  (make-string (- (string-length line) (string-length (trim-start line))) #\space))

(define (markdown-line line code? width)
  (define trimmed (trim line))
  (if code?
      (wrap-segs (list (seg "│ " 'dim) (seg line 'code)) width (list (seg "│ " 'dim)))
      (let* ([level (heading-level trimmed)]
             [segs
              (cond
                [(and (> level 0) (< level 7))
                 (list (seg (trim (substring trimmed level (string-length trimmed))) 'heading))]
                [(numbered-item trimmed)
                 (let ([n (numbered-item trimmed)])
                   (cons (seg (string-append (leading-spaces line) (substring trimmed 0 n)) 'list-mark)
                         (inline-segs (substring trimmed n (string-length trimmed)) 'text)))]
                [(or (starts-with? trimmed "- ") (starts-with? trimmed "* "))
                 (cons (seg (string-append (leading-spaces line) "• ") 'list-mark)
                       (inline-segs (substring trimmed 2 (string-length trimmed)) 'text))]
                [(starts-with? trimmed "> ")
                 (cons (seg "▎ " 'dim) (inline-segs (substring trimmed 2 (string-length trimmed)) 'dim))]
                [(equal? trimmed "---") (list (seg (make-string (max 1 (min width 24)) #\─) 'dim))]
                [else (inline-segs line 'text)])]
             ;; list items and quotes hang their continuation lines
             [hang (if (and (pair? segs) (member (cdr (car segs)) '(dim list-mark)))
                       (list (seg (make-string (text-width (car (car segs))) #\space) 'dim))
                       '())])
        (wrap-segs segs width hang))))

(define (table-cells row)
  (define parts (map trim (split-many (trim row) "|")))
  (define inner (if (and (pair? parts) (equal? (car parts) "")) (cdr parts) parts))
  (if (and (pair? inner) (equal? (last inner) "")) (reverse (cdr (reverse inner))) inner))

(define (separator-row? cells)
  (and (pair? cells)
       (null? (filter (lambda (c) (not (and (> (string-length c) 0)
                                           (null? (filter (lambda (ch) (not (member ch '(#\- #\:))))
                                                          (string->list c))))))
                      cells))))

(define (indices n)
  (let loop ([i (- n 1)] [acc '()])
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; aligned columns, or one card per row when the table is too wide
(define (table-lines rows width)
  (define body (filter (lambda (r) (not (separator-row? r))) (map table-cells rows)))
  (define cols (foldl (lambda (r acc) (max acc (length r))) 0 body))
  (define cells (map (lambda (r i) (map (lambda (c) (inline-segs c (if (= i 0) 'bold 'text))) r))
                     body (indices (length body))))
  (define widths
    (map (lambda (k)
           (foldl (lambda (r acc) (if (< k (length r)) (max acc (segs-width (list-ref r k))) acc)) 0 cells))
         (indices cols)))
  (define total (+ (foldl + 0 widths) (* 3 (max 0 (- cols 1)))))
  (define (pad segs w) (append segs (list (seg (make-string (max 0 (- w (segs-width segs))) #\space) 'text))))
  (if (> total width)
      (let ([header (if (pair? cells) (car cells) '())])
        (apply append
               (map (lambda (r)
                      (append
                       (wrap-segs (cons (seg "▸ " 'list-mark) (if (pair? r) (car r) '())) width (list (seg "  " 'dim)))
                       (apply append
                              (map (lambda (c k)
                                     (define name (if (< (+ k 1) (length header)) (list-ref header (+ k 1)) '()))
                                     (wrap-segs (append (list (seg "  " 'dim))
                                                        (map (lambda (sg) (seg (car sg) 'dim)) name)
                                                        (list (seg ": " 'dim))
                                                        c)
                                                width (list (seg "    " 'dim))))
                                   (if (pair? r) (cdr r) '())
                                   (indices (max 0 (- (length r) 1)))))))
                    (if (pair? cells) (cdr cells) '()))))
      (apply append
             (map (lambda (r i)
                    (define line
                      (apply append (map (lambda (k)
                                           (define c (if (< k (length r)) (list-ref r k) '()))
                                           (if (= k 0)
                                               (pad c (list-ref widths k))
                                               (cons (seg " │ " 'dim) (pad c (list-ref widths k)))))
                                         (indices cols))))
                    (if (= i 0)
                        (list line (list (seg (string-join (map (lambda (w) (make-string w #\─)) widths) "─┼─") 'dim)))
                        (list line)))
                  cells (indices (length cells))))))

;; a line that starts its own block rather than continuing a paragraph
(define (block-start? trimmed)
  (or (equal? trimmed "")
      (starts-with? trimmed "```")
      (starts-with? trimmed "#")
      (starts-with? trimmed "- ")
      (starts-with? trimmed "* ")
      (starts-with? trimmed "> ")
      (starts-with? trimmed "|")
      (equal? trimmed "---")
      (numbered-item trimmed)))

;; soft line breaks join a paragraph, with a space only between latin words
(define (join-soft-breaks lines)
  (let loop ([ls lines] [code? #f] [out '()])
    (cond
      [(null? ls) (reverse out)]
      [else
       (define line (car ls))
       (define trimmed (trim line))
       (define prev (and (pair? out) (car out)))
       (cond
         [(starts-with? trimmed "```") (loop (cdr ls) (not code?) (cons line out))]
         [code? (loop (cdr ls) #t (cons line out))]
         [(and prev
               (not (block-start? trimmed))
               (not (blank? prev))
               (not (starts-with? (trim prev) "```"))
               (not (starts-with? (trim prev) "#"))
               (not (equal? (trim prev) "---"))
               (not (ends-with? prev "  ")))
          (define a (string-ref prev (- (string-length prev) 1)))
          (define b (string-ref trimmed 0))
          (loop (cdr ls) #f
                (cons (string-append prev (if (and (word-char? a) (word-char? b)) " " "") trimmed) (cdr out)))]
         [else (loop (cdr ls) #f (cons line out))])])))

;; markdown text -> wrapped lines, each prefixed by indent
(define (markdown-lines text width indent)
  (define inner (- width (segs-width indent)))
  (let loop ([ls (join-soft-breaks (split-many (string-replace text "\t" "  ") "\n"))] [code? #f] [out '()])
    (cond
      [(null? ls) (reverse out)]
      [(starts-with? (trim (car ls)) "```") (loop (cdr ls) (not code?) out)]
      [(and (not code?) (starts-with? (trim (car ls)) "|"))
       (define rows (let take-rows ([ls ls] [acc '()])
                      (if (and (pair? ls) (starts-with? (trim (car ls)) "|"))
                          (take-rows (cdr ls) (cons (car ls) acc))
                          (reverse acc))))
       (loop (list-tail ls (length rows)) #f
             (append (reverse (map (lambda (l) (append indent l)) (table-lines rows inner))) out))]
      [else
       (loop (cdr ls) code?
             (append (reverse (map (lambda (l) (append indent l)) (markdown-line (car ls) code? inner))) out))])))

(define (plain-lines text width indent style)
  (define inner (- width (segs-width indent)))
  (apply append
         (map (lambda (l) (map (lambda (w) (append indent w)) (wrap-segs (list (seg l style)) inner '())))
              (split-many (string-replace text "\t" "  ") "\n"))))

;;; tool calls

(define (text-lines t) (if (string? t) (split-many t "\n") '()))

;; lines shared at the head and tail of old and new
(define (common-head a b)
  (let loop ([a a] [b b] [n 0])
    (if (and (pair? a) (pair? b) (equal? (car a) (car b))) (loop (cdr a) (cdr b) (+ n 1)) n)))

;; compact diff: drops the common head and tail and keeps one line around it
(define (diff-lines old-text new-text width)
  (define old (text-lines old-text))
  (define new (text-lines new-text))
  (define prefix (common-head old new))
  (define old* (list-tail old prefix))
  (define new* (list-tail new prefix))
  (define suffix (common-head (reverse old*) (reverse new*)))
  (define removed (take-at-most old* (- (length old*) suffix)))
  (define added (take-at-most new* (- (length new*) suffix)))
  (define before (if (> prefix 0) (list (list-ref old (- prefix 1))) '()))
  (define after (if (> suffix 0) (list (list-ref old* (- (length old*) suffix))) '()))
  (define (row mark text style)
    (list (seg "    " 'dim) (seg (truncate-text (string-append mark text) (- width 4)) style)))
  (append (map (lambda (l) (row "  " l 'dim)) before)
          (map (lambda (l) (row "- " l 'diff-del)) removed)
          (map (lambda (l) (row "+ " l 'diff-add)) added)
          (map (lambda (l) (row "  " l 'dim)) after)))

(define (diff-stat old-text new-text)
  (define old (text-lines old-text))
  (define new (text-lines new-text))
  (define prefix (common-head old new))
  (define suffix (common-head (reverse (list-tail old prefix)) (reverse (list-tail new prefix))))
  (string-append "+" (number->string (- (length new) prefix suffix))
                 " -" (number->string (- (length old) prefix suffix))))

(define (strip-fences text)
  (string-join (filter (lambda (l) (not (starts-with? (trim l) "```"))) (split-many text "\n")) "\n"))

(define (collapse lines limit expanded?)
  (if (or expanded? (<= (length lines) limit))
      lines
      (append (take-at-most lines limit)
              (list (list (seg (string-append "    … +" (number->string (- (length lines) limit))
                                              " lines (click or ^t to expand)")
                               'dim))))))

;; rel: path -> workspace-relative path for display
(define (tool-content-lines content width limit expanded? rel)
  (apply append
         (map (lambda (c)
                (define type (jget c 'type))
                (cond
                  [(equal? type "diff")
                   (cons (list (seg "  ⎿ " 'dim)
                               (seg (rel (or (jget c 'path) "")) 'text)
                               (seg (string-append "  " (diff-stat (jget c 'oldText) (jget c 'newText))) 'dim))
                         (collapse (diff-lines (jget c 'oldText) (jget c 'newText) width) (max 12 limit) expanded?))]
                  [(equal? type "content")
                   (define text (jget c 'content 'text))
                   (cond
                     [(or (not (string? text)) (blank? (strip-fences text))) '()]
                     ;; command and file output arrives fenced; prose is markdown
                     [(starts-with? (trim text) "```")
                      (collapse (plain-lines (strip-fences text) width (list (seg "    " 'dim)) 'dim) limit expanded?)]
                     [else (collapse (markdown-lines (trim text) width (list (seg "    " 'dim))) limit expanded?)])]
                  [else '()]))
              content)))

(define (status-style status)
  (cond [(equal? status "completed") 'ok]
        [(equal? status "failed") 'error]
        [(equal? status "in_progress") 'running]
        [else 'pending]))

(define (plan-lines entries width)
  (apply append
         (map (lambda (p)
                (define st (jget p 'status))
                (define mark (cond [(equal? st "completed") "☒ "] [(equal? st "in_progress") "◐ "] [else "☐ "]))
                (define style (cond [(equal? st "completed") 'dim] [(equal? st "in_progress") 'running] [else 'text]))
                (wrap-segs (list (seg (string-append "  " mark) style) (seg (or (jget p 'content) "") style))
                           width (list (seg "    " style))))
              entries)))

;;; entries

(define (entry-lines-uncached e width expanded? rel)
  (define kind (entry-kind e))
  (define text (or (entry-get e 'text) ""))
  (cond
    [(equal? kind 'user)
     (append
      (apply append
             (map (lambda (l i)
                    (wrap-segs (list (seg (if (= i 0) "❯ " "  ") 'user-mark) (seg l 'user))
                               width (list (seg "  " 'user))))
                  (split-many text "\n")
                  (indices (length (split-many text "\n")))))
      (map (lambda (a) (list (seg "  " 'dim) (seg a 'attachment)))
           (or (entry-get e 'attachments) '())))]
    [(equal? kind 'agent)
     (define lines (markdown-lines (trim text) width (list (seg "  " 'text))))
     (if (null? lines) '() (cons (cons (seg "⏺ " 'agent-mark) (cdr (car lines))) (cdr lines)))]
    [(equal? kind 'thought)
     (cons (list (seg "✻ Thinking" 'thought))
           (collapse (plain-lines (trim text) width (list (seg "  " 'thought)) 'thought) 3 expanded?))]
    [(equal? kind 'tool)
     (define status (or (entry-get e 'status) "pending"))
     (define title (string-replace (or (entry-get e 'title) "tool") "\n" " "))
     (define head (wrap-segs (list (seg "⏺ " (status-style status)) (seg title 'tool-title))
                             width (list (seg "  " 'tool-title))))
     (append
      ;; a long shell command would flood the transcript
      (if (or expanded? (<= (length head) 2))
          head
          (list (car head) (append (cadr head) (list (seg " …" 'dim)))))
      (tool-content-lines (or (entry-get e 'content) '()) width 4 expanded? rel))]
    [(equal? kind 'plan)
     (cons (list (seg "⏺ " 'agent-mark) (seg "Plan" 'tool-title))
           (plan-lines (or (entry-get e 'entries) '()) width))]
    [(equal? kind 'error) (plain-lines text width (list (seg "! " 'error)) 'error)]
    [else (plain-lines text width (list (seg "· " 'dim)) 'dim)]))

;; entry -> (rev width expanded? lines), so a stream re-lays out only the
;; entry that changed
(define *cache* (hash))

(define (entry-lines e width expand-all? rel)
  (define expanded? (or expand-all? (and (entry-get e 'expanded) #t)))
  (define key (list (entry-rev e) width expanded?))
  (define hit (hash-try-get *cache* e))
  (if (and hit (equal? (car hit) key))
      (cdr hit)
      (let ([lines (entry-lines-uncached e width expanded? rel)])
        (when (> (hash-length *cache*) 2000) (set! *cache* (hash)))
        (set! *cache* (hash-insert *cache* e (cons key lines)))
        lines)))

;;; permission prompt

;; perm: hash with 'title 'content 'options 'index
(define (permission-lines perm width limit rel)
  (define opts (hash-ref perm 'options))
  (append
   (list (list (seg "? " 'warning) (seg (truncate-text (hash-ref perm 'title) (- width 2)) 'tool-title)))
   (tool-content-lines (hash-ref perm 'content) width limit #f rel)
   (map (lambda (o i)
          (define selected? (= i (hash-ref perm 'index)))
          (list (seg (if selected? " ❯ " "   ") 'accent)
                (seg (string-append (number->string (+ i 1)) ". " (or (jget o 'name) "?"))
                     (if selected? 'accent 'text))))
        opts (indices (length opts)))))

;;; input box

;; plain chars -> row strings, breaking on newlines and width
(define (wrap-chars chars width)
  (let loop ([cs chars] [row '()] [w 0] [rows '()])
    (cond
      [(null? cs) (reverse (cons (list->string (reverse row)) rows))]
      [(equal? (car cs) #\newline) (loop (cdr cs) '() 0 (cons (list->string (reverse row)) rows))]
      [else
       (define cw (char-width (car cs)))
       (if (> (+ w cw) width)
           (loop (cdr cs) (list (car cs)) cw (cons (list->string (reverse row)) rows))
           (loop (cdr cs) (cons (car cs) row) (+ w cw) rows))])))
