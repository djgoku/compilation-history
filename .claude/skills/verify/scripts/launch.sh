#!/usr/bin/env bash
# Start a disposable Emacs with history and the agent interface enabled, using
# a fresh database. Default: batch Emacs (agent CLI recipes). --tui: terminal
# Emacs (emacs -nw) in a private tmux server, for keyboard-driven recipes.
# Prints `export VERIFY_ROOT=...` on success.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../.." && pwd)
mode=batch
case "${1:-}" in
  '') ;;
  --tui) mode=tui ;;
  *) printf 'Usage: launch.sh [--tui]\n' >&2; exit 2 ;;
esac
tools=(emacs emacsclient jq git)
[ "$mode" = batch ] || tools+=(tmux)
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || { printf 'Missing required tool: %s\n' "$tool" >&2; exit 1; }
done
root=$(mktemp -d /tmp/ch-verify.XXXXXX)
printf 'owned\n' > "$root/owned-fixture"
mkdir "$root/work"
git -C "$root/work" init -q -b verify-branch
git -C "$root/work" -c user.name=verify -c user.email=verify@invalid -c commit.gpgsign=false \
  commit -q --allow-empty -m 'verify fixture'
mkfifo "$root/ready"
exec 3<> "$root/ready"
if [ "$mode" = batch ]; then
  CH_AGENT_TEST_ROOT="$root" nohup emacs --batch -Q -L "$repo" \
    -l "$repo/tests/compilation-history-agent-server-fixture.el" \
    < /dev/null > "$root/server.log" 2>&1 &
  printf '%s\n' "$!" > "$root/server.pid"
else
  tmux -S "$root/tmux.sock" new-session -d -s verify -x 160 -y 48 \
    -e "CH_VERIFY_ROOT=$root" -c "$root/work" \
    emacs -nw -Q -L "$repo" -l "$here/tui-init.el"
fi
if ! IFS= read -r -t 20 -u 3 line || [ "$line" != ready ]; then
  printf 'Emacs not ready within 20s.\n' >&2
  [ ! -f "$root/server.log" ] || tail -40 "$root/server.log" >&2
  [ ! -S "$root/tmux.sock" ] || tmux -S "$root/tmux.sock" capture-pane -p -t verify >&2 || true
  [ ! -S "$root/tmux.sock" ] || tmux -S "$root/tmux.sock" kill-server 2>/dev/null || true
  [ ! -f "$root/server.pid" ] || kill "$(cat "$root/server.pid")" 2>/dev/null || true
  exit 1
fi
exec 3>&-
# A read-only tmux attach would make tmux reject keys.sh, so the watcher only captures the pane.
[ "$mode" = batch ] || printf 'Watch live: while :; do printf '\''\\033[H'\''; tmux -S %s/tmux.sock capture-pane -e -p -t verify; sleep 0.3; done\n' "$root" >&2
printf 'export VERIFY_ROOT=%s\n' "$root"
