#!/bin/bash
# Clear ntfy notification cooldown when user interacts with a CC session.
# Added to UserPromptSubmit hook so that after you respond, the next idle
# event will trigger a fresh notification.
INPUT=$(cat)
CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
PROJECT=""
if [[ -n "$CWD" ]]; then
    PROJECT=$(basename "$CWD")
fi

_RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}"
COOLDOWN_FILE="${_RUNTIME_BASE}/tap-to-tmux-cooldown/${PROJECT:-unknown}"
if [[ -f "$COOLDOWN_FILE" ]]; then
    rm -f "$COOLDOWN_FILE"
    mkdir -p "${_RUNTIME_BASE}/tap-to-tmux-logs"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Cooldown cleared for ${PROJECT}" >> "${_RUNTIME_BASE}/tap-to-tmux-logs/cooldown-clear.log"
fi
exit 0
