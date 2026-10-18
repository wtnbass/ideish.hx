;; Change detection and git status.
;;
;; The native watcher collects filesystem events and runs `git status` on Rust
;; threads. The shared tick (tick.scm) drains what it collected; when nothing
;; happened that is a single FFI call. No Steel code runs off the main thread
;; (mattwparas/helix#138).

(require "helix/editor.scm")
(require "helix/misc.scm")
(require-builtin steel/time)
(require "tick.scm")

(#%require-dylib "libideish"
                 (only-in watcher-new
                          watcher-set-dirs!
                          watcher-set-files!
                          watcher-drain!
                          watcher-git-status!
                          watcher-git?))

(provide watch-start!
         watch-on-dirs!
         watch-set-dirs!
         watch-refresh-git!
         git-available?
         git-branch
         git-ahead
         git-behind
         git-status-of
         git-revision)

;; git status runs this long after the last change, so a burst of writes
;; (a checkout, a formatter) costs one run
(define *git-quiet-ms* 300)

(define *watcher* #f)
(define *dir-listeners* '())
(define *git-due* #f)
(define *last-dirs* "")

(define *branch* #f)
(define *ahead* 0)
(define *behind* 0)
(define *statuses* (hash))
;; bumped on every git update so parts can cache derived data
(define *revision* 0)

(define (git-available?) (and *watcher* (watcher-git? *watcher*)))
(define (git-branch) *branch*)
(define (git-ahead) *ahead*)
(define (git-behind) *behind*)
(define (git-revision) *revision*)

;; 'modified 'added 'deleted 'renamed 'untracked 'ignored 'conflict, or #f
(define (git-status-of path) (hash-try-get *statuses* path))

;; proc: (list-of-dirs) -> any
(define (watch-on-dirs! proc)
  (set! *dir-listeners* (append *dir-listeners* (list proc))))

;; Directories whose listing is on screen; changes elsewhere are dropped in Rust
(define (watch-set-dirs! dirs)
  (define joined (string-join dirs "\n"))
  (when (and *watcher* (not (equal? joined *last-dirs*)))
    (set! *last-dirs* joined)
    (watcher-set-dirs! *watcher* joined)))

(define (watch-refresh-git!)
  (when *watcher* (watcher-git-status! *watcher*)))

(define (open-paths)
  (filter string?
          (map (lambda (id) (with-handler (lambda (_) #f) (editor-document->path id)))
               (editor-all-documents))))

(define (sync-open-files!)
  (when *watcher*
    (watcher-set-files! *watcher* (string-join (open-paths) "\n"))))

(define (doc-for-path path)
  (let loop ([ids (editor-all-documents)])
    (cond
      [(null? ids) #f]
      [(equal? (with-handler (lambda (_) #f) (editor-document->path (car ids))) path) (car ids)]
      [else (loop (cdr ids))])))

;; Reload a buffer changed on disk, unless it has unsaved edits or the change
;; is Helix's own save
(define (maybe-reload! path)
  (define doc (doc-for-path path))
  (when (and doc (not (editor-document-dirty? doc)) (path-exists? path))
    (define saved (editor-document-last-saved doc))
    (define modified (fs-metadata-modified (file-metadata path)))
    (when (and saved (system-time<? saved modified))
      (editor-document-reload doc))))

(define (apply-git-result! result)
  (set! *branch* (list-ref result 0))
  (set! *ahead* (list-ref result 1))
  (set! *behind* (list-ref result 2))
  (set! *statuses*
        (let loop ([xs (list-ref result 3)] [acc (hash)])
          (if (or (null? xs) (null? (cdr xs)))
              acc
              (loop (cddr xs) (hash-insert acc (car xs) (string->symbol (cadr xs)))))))
  (set! *revision* (+ *revision* 1)))

(define (handle! batch)
  (define git-dirty? (list-ref batch 0))
  (define dirs (list-ref batch 1))
  (define files (list-ref batch 2))
  (define git-result (list-ref batch 3))
  (when git-dirty?
    (set! *git-due* (+ (current-milliseconds) *git-quiet-ms*)))
  (unless (null? dirs)
    (for-each (lambda (f) (f dirs)) *dir-listeners*))
  (for-each (lambda (p) (with-handler (lambda (_) void) (maybe-reload! p))) files)
  (when git-result
    (apply-git-result! git-result))
  void)

;; tick task: #t while there is something to do
(define (poll)
  (define batch (watcher-drain! *watcher*))
  (when batch (handle! batch))
  (define due? (and *git-due* (>= (current-milliseconds) *git-due*)))
  (when due?
    (set! *git-due* #f)
    (watcher-git-status! *watcher*))
  (if (or batch *git-due* due?) #t #f))

(define (watch-start!)
  (unless *watcher*
    (define w (watcher-new (helix-find-workspace)))
    (when w
      (set! *watcher* w)
      (sync-open-files!)
      (register-hook 'document-opened (lambda (_) (sync-open-files!)))
      (register-hook 'document-closed (lambda (_) (sync-open-files!)))
      (watcher-git-status! w)
      (tick-register! poll))))
