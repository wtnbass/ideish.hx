(require "check.scm")
(require "../agent/protocol.scm")
(require "../agent/session.scm")
(require "../agent/layout.scm")

(define (texts line) (apply string-append (map car line)))
(define (all-texts lines) (map texts lines))
(define (styles line) (map cdr line))
(define (rel p) p)

(check "wrapping moves latin words whole" (all-texts (wrap-segs (list (seg "hello wide world" 'text)) 11 '()))
       (list "hello wide" "world"))
(check "CJK text breaks anywhere" (all-texts (wrap-segs (list (seg "日本語の文章" 'text)) 6 '()))
       (list "日本語" "の文章"))
(check "continuation lines take the indent" (all-texts (wrap-segs (list (seg "aaa bbb" 'text)) 4 (list (seg "  " 'dim))))
       (list "aaa" "  bbb"))

(check "inline code, bold and links get styles"
       (styles (inline-segs "a `b` **c** [d](u)" 'text))
       (list 'text 'code 'text 'bold 'text 'link))

(define md (markdown-lines "# Title\n\nsoft\nbreak\n\n- item\n1. first\n\n```\ncode\n```" 40 '()))
(check "markdown lines" (all-texts md) (list "Title" "" "soft break" "" "• item" "1. first" "" "│ code"))
(check "a heading is styled" (cdr (car (car md))) 'heading)

(define table (markdown-lines "| a | bb |\n|---|---|\n| 1 | 2 |" 40 '()))
(check "a table aligns its columns" (all-texts table) (list "a │ bb" "──┼───" "1 │ 2 "))

(check "diff keeps one line of context"
       (all-texts (diff-lines "a\nb\nc" "a\nB\nc" 40))
       (list "      a" "    - b" "    + B" "      c"))
(check "diff stat" (diff-stat "a\nb\nc" "a\nB\nB2\nc") "+2 -1")

(define s (make-session "/w"))
(session-apply-update! s (string->jsexpr "{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"t\",\"title\":\"Run\",\"status\":\"completed\",\"content\":[{\"type\":\"content\",\"content\":{\"type\":\"text\",\"text\":\"```\\n1\\n2\\n3\\n4\\n5\\n6\\n```\"}}]}"))
(define tool (car (session-entries s)))
(check "long tool output collapses" (length (entry-lines tool 40 #f rel)) 6)
(check "expanding shows all of it" (length (entry-lines tool 40 #t rel)) 7)
(entry-set! tool 'expanded #t)
(check "an entry can be expanded on its own" (length (entry-lines tool 40 #f rel)) 7)

(session-push! s 'user (hash 'text "line one\nline two" 'attachments (list "@a.rs:1-2")))
(check "a user entry shows its attachments"
       (all-texts (entry-lines (car (session-entries s)) 40 #f rel))
       (list "❯ line one" "  line two" "  @a.rs:1-2"))

(define perm (hash 'title "Edit x" 'content '() 'index 1
                   'options (list (hash 'name "Yes") (hash 'name "No"))))
(check "permission lines mark the selected option"
       (all-texts (permission-lines perm 40 6 rel))
       (list "? Edit x" "   1. Yes" " ❯ 2. No"))

(check "input wraps on newlines and width" (wrap-chars (string->list "abcd\nef") 3) (list "abc" "d" "ef"))
(check-summary!)
