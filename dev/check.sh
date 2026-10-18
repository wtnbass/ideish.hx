#!/bin/sh
# Launch hx with the dev config in tmux and print any steel load error.
cd "$(dirname "$0")/.."
tmux kill-session -t ideish 2>/dev/null
tmux new-session -d -s ideish -x "${COLS:-160}" -y "${ROWS:-40}" "cd $PWD && HELIX_STEEL_CONFIG=$PWD/dev hx $*"
sleep 3
tmux capture-pane -t ideish -p | grep -A12 "error\[" || echo "loaded ok"
