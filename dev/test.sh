#!/bin/sh
# Smoke test: start Helix with dev/init.scm in tmux and check that the bars
# and the tree draw. Layout and tree logic are covered by `make test`.
cd "$(dirname "$0")/.."
ROOT=$PWD
WS=$(mktemp -d)
S=ideish-smoke
fail=0
cleanup() { tmux kill-session -t $S 2>/dev/null; rm -rf "$WS"; }
trap cleanup EXIT

(cd "$WS" && git init -q -b main && mkdir src && echo one > a.txt && echo fn > src/main.rs \
  && git add . && git -c user.email=t@t -c user.name=t commit -qm init)

screen() { tmux capture-pane -t $S -p; }
expect() {
  i=0
  while [ $i -lt 25 ]; do
    if screen | grep -qE -- "$1"; then echo "ok   $2"; return; fi
    sleep 0.2; i=$((i + 1))
  done
  echo "FAIL $2 (missing: $1)"; fail=1
}

tmux kill-session -t $S 2>/dev/null
tmux new-session -d -s $S -x 160 -y 30 "cd $WS && IDEISH_AGENT='node $ROOT/dev/fake-agent.mjs' HELIX_STEEL_CONFIG=$ROOT/dev hx a.txt src/main.rs"
sleep 3
if screen | grep -q "error\["; then screen | grep -A12 "error\["; exit 1; fi

expect "NORMAL" "statusline draws"
expect " main" "statusline shows the git branch"
expect "a\.txt .*main\.rs" "bufferline shows both buffers"
expect "^ [^ ]+ a\.txt *$" "breadcrumb shows the focused file"
tmux send-keys -t $S Space e
expect "$(basename "$WS")" "tree header shows the workspace"
expect "src" "tree lists the workspace"
# Esc then Enter too quickly reads as Alt-Enter
tmux send-keys -t $S Escape; sleep 0.3; tmux send-keys -t $S Enter a
expect "Fake Agent" "agent pane starts the agent"
tmux send-keys -t $S -l "md"; tmux send-keys -t $S Enter
expect "Summary" "agent pane shows the reply"

[ $fail -eq 0 ] && echo "smoke test passed"
exit $fail
