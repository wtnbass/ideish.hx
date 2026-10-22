;; File tree state: which directories are open and the cached listing of each.
;; Pure apart from the listing function the caller passes in, so tests can feed
;; a fake filesystem.
;;
;; Listings are cached per directory and dropped only when the watcher reports
;; a change inside that directory, so building the rows touches the disk only
;; for directories that changed.

(provide make-tree
         tree-root
         tree-open?
         tree-open!
         tree-close!
         tree-toggle!
         tree-reveal!
         tree-invalidate!
         tree-invalidate-all!
         tree-rows
         tree-open-dirs
         changed-paths
         parent-path
         path-within?
         row row? row-path row-name row-depth row-dir? row-open?)

(struct row (path name depth dir? open?) #:transparent)

;; open: hash of directory -> #t for the directories shown expanded
;; listings: path -> list of (path . dir?), sorted
(struct tree (root open listings) #:mutable)

(define (make-tree root)
  (tree root (hash root #t) (hash)))

(define (parent-path path)
  (define parts (split-many path "/"))
  (if (<= (length parts) 1)
      path
      (let ([parent (string-join (take parts (- (length parts) 1)) "/")])
        (if (equal? parent "") "/" parent))))

(define (path-within? path dir)
  (or (equal? path dir)
      (starts-with? path (if (ends-with? dir "/") dir (string-append dir "/")))))

(define (tree-open? t path)
  (hash-contains? (tree-open t) path))

(define (tree-open! t path)
  (set-tree-open! t (hash-insert (tree-open t) path #t)))

(define (tree-close! t path)
  (unless (equal? path (tree-root t))
    (set-tree-open! t (hash-remove (tree-open t) path))))

(define (tree-toggle! t path)
  (if (tree-open? t path) (tree-close! t path) (tree-open! t path)))

;; Opens every directory from the root down to the parent of path
(define (tree-reveal! t path)
  (when (path-within? path (tree-root t))
    (let loop ([dir (parent-path path)])
      (when (and (path-within? dir (tree-root t)) (not (equal? dir path)))
        (tree-open! t dir)
        (unless (equal? dir (tree-root t))
          (loop (parent-path dir)))))))

(define (tree-invalidate! t path)
  (set-tree-listings! t (hash-remove (tree-listings t) path)))

(define (tree-invalidate-all! t)
  (set-tree-listings! t (hash)))

(define (entry<? a b)
  (cond
    [(and (cdr a) (not (cdr b))) #t]
    [(and (cdr b) (not (cdr a))) #f]
    [else (string<? (string-downcase (file-name (car a))) (string-downcase (file-name (car b))))]))

(define (listing t dir list-dir)
  (define cached (hash-try-get (tree-listings t) dir))
  (or cached
      (let ([entries (sort (list-dir dir) entry<?)])
        (set-tree-listings! t (hash-insert (tree-listings t) dir entries))
        entries)))

;; list-dir: dir -> list of (path . dir?)
;; skip?: path name dir? -> #t to leave the entry out
(define (tree-rows t list-dir skip?)
  (define root (tree-root t))
  (define (walk dir depth acc)
    (foldl (lambda (entry acc)
             (define path (car entry))
             (define dir? (cdr entry))
             (define name (file-name path))
             (if (skip? path name dir?)
                 acc
                 (let* ([open? (and dir? (tree-open? t path))]
                        [acc (cons (row path name depth dir? open?) acc)])
                   (if open? (walk path (+ depth 1) acc) acc))))
           acc
           (listing t dir list-dir)))
  (reverse (walk root 0 (list (row root (file-name root) -1 #t #t)))))

;; Open directories whose parents are all open, i.e. whose listing is on screen
(define (tree-open-dirs t)
  (define root (tree-root t))
  (filter (lambda (dir)
            (let loop ([d dir])
              (cond
                [(equal? d root) #t]
                [(not (tree-open? t d)) #f]
                [(not (path-within? d root)) #f]
                [else (loop (parent-path d))])))
          (hash-keys->list (tree-open t))))

;; The changed files under root, by path: entries is (path . status) as git
;; reported them, where a directory carries the status of what is below it and
;; an untracked directory stands for its contents
(define (changed-paths entries root)
  (define changed (filter (lambda (e) (and (not (equal? (cdr e) 'ignored))
                                           (path-within? (car e) root)
                                           (not (equal? (car e) root))))
                          entries))
  (define (has-changes-below? path)
    (let loop ([es changed])
      (cond
        [(null? es) #f]
        [(and (not (equal? (car (car es)) path)) (path-within? (car (car es)) path)) #t]
        [else (loop (cdr es))])))
  (sort (filter (lambda (e) (not (has-changes-below? (car e)))) changed)
        (lambda (a b) (string<? (car a) (car b)))))
