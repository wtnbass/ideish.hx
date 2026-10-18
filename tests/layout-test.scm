(require "check.scm")
(require "../core/layout.scm")

(define tree (spec 'tree 'pane 'left 30))
(define agent (spec 'agent 'pane 'right 60))
(define tabs (spec 'bufferline 'bar 'top 1))
(define status (spec 'statusline 'bar 'bottom 1))

(define l (compute-layout 200 50 (list tree agent tabs status)))
(check "tree spans from the top to above the command line" (layout-rect-of l 'tree) (rect 0 0 30 49))
(check "agent sits on the right edge" (layout-rect-of l 'agent) (rect 140 0 60 49))
(check "bufferline covers the centre column" (layout-rect-of l 'bufferline) (rect 30 0 110 1))
(check "statusline sits above the command line" (layout-rect-of l 'statusline) (rect 30 48 110 1))
(check "clip reserves both panes and the top bar" (layout-clip l) (list 30 60 1 0))

(define bare (compute-layout 100 30 (list status)))
(check "without panes the bars span the full width" (layout-rect-of bare 'statusline) (rect 0 28 100 1))
(check "without panes nothing is clipped" (layout-clip bare) (list 0 0 0 0))

(define narrow (compute-layout 90 30 (list tree agent)))
(check "the last pane shrinks first so the editor keeps 20 columns" (layout-rect-of narrow 'agent) (rect 50 0 40 29))
(check "the first pane keeps its width" (layout-rect-of narrow 'tree) (rect 0 0 30 29))

(define tiny (compute-layout 40 10 (list tree agent)))
(check "a pane squeezed to nothing is dropped" (layout-rect-of tiny 'agent) #f)
(check "the remaining pane leaves 20 columns" (layout-rect-of tiny 'tree) (rect 0 0 20 9))

(define stacked (compute-layout 100 30 (list tabs (spec 'crumbs 'bar 'top 1))))
(check "top bars stack downwards" (layout-rect-of stacked 'crumbs) (rect 0 1 100 1))
(check "stacked top bars add to the top clip" (layout-clip stacked) (list 0 0 2 0))

(check "rect-contains? includes the origin" (rect-contains? (rect 2 3 4 5) 2 3) #t)
(check "rect-contains? excludes the far edge" (rect-contains? (rect 2 3 4 5) 6 3) #f)

(check-summary!)
