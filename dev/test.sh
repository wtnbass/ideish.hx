#!/bin/sh
# Smoke test: start Helix with dev/init.scm in tmux and check that the bars,
# the tree, the agent and the terminal draw. Layout and tree logic are covered
# by `make test`. The terminal checks are skipped when libideish was built
# without it (make install TERMINAL=1).
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
# SMOKE_DEBUG=1 prints the screen when a check fails
absent() {
  sleep 0.5
  if screen | grep -qE -- "$1"; then echo "FAIL $2 (still there: $1)"; fail=1; else echo "ok   $2"; fi
}
expect() {
  i=0
  while [ $i -lt 25 ]; do
    if screen | grep -qE -- "$1"; then echo "ok   $2"; return; fi
    sleep 0.2; i=$((i + 1))
  done
  echo "FAIL $2 (missing: $1)"; fail=1; [ -n "$SMOKE_DEBUG" ] && screen
}

tmux kill-session -t $S 2>/dev/null
# the session gets the tmux server's environment, so pass STEEL_HOME on
tmux new-session -d -s $S -x 160 -y 30 "cd $WS && ${STEEL_HOME:+STEEL_HOME=$STEEL_HOME }SHELL=/bin/sh IDEISH_AGENT='node $ROOT/dev/fake-agent.mjs' HELIX_STEEL_CONFIG=$ROOT/dev hx a.txt src/main.rs"
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

tmux send-keys -t $S Escape; sleep 0.3
tmux send-keys -t $S -l ':ideish-health'; tmux send-keys -t $S Enter
expect "Terminal" "health shows the terminal"
if screen | grep -q "not built: rebuild libideish"; then
  echo "skip terminal (libideish was built without it)"
else
  # any key closes the health notice
  tmux send-keys -t $S Escape; sleep 0.3; tmux send-keys -t $S Enter t
  expect "sh-[0-9.]+\\$" "terminal pane shows the shell"
  tmux send-keys -t $S -l 'echo ideish-$((1+1))'; tmux send-keys -t $S Enter
  expect "ideish-2" "terminal runs a command"
  expect "NORMAL" "statusline stays above the terminal"
  # C-\ gives the keys back to the editor
  tmux send-keys -t $S 'C-\'; sleep 0.3
  tmux send-keys -t $S -l ':echo ideish-message'; tmux send-keys -t $S Enter
  expect "^ *│? *ideish-message" "messages stay visible above the terminal"
  # the editor then hides the pane
  tmux send-keys -t $S Enter t
  absent "ideish-2" "the editor hides the terminal again"
  # the command that focuses the pane runs after the keys already queued
  tmux send-keys -t $S Enter t; sleep 0.5
  tmux send-keys -t $S -l 'exit'; tmux send-keys -t $S Enter
  expect "terminal: sh exited" "exiting the shell closes the pane"
fi

[ $fail -eq 0 ] && echo "smoke test passed"
exit $fail
