#!/bin/bash
# Attach to a tmux session from mobile with independent viewport and pane zoom
# Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]

# Blink Shell may set TMUX in the calling environment (local tmux),
# which blocks tmux new-session/attach with "should be nested with care".
# We always need to create/attach to the server's tmux, so unset it.
unset TMUX

SESSION="${1:?Usage: tmux-mobile-attach.sh SESSION [PANE_INDEX]}"
PANE="${2:-}"
LOG="/tmp/tmux-mobile-attach.log"

ts() { date '+%H:%M:%S.%3N'; }
log() { echo "[$(ts)] $*" >> "$LOG"; echo "$*"; }
log_sessions() { tmux list-sessions -F '  #{session_name} group=#{session_group} attached=#{session_attached}' 2>/dev/null >> "$LOG"; }

# Safety net: if a stale deep link targets a mob-* session, resolve to its parent
if [[ "$SESSION" == mob-* ]]; then
    _parent=$(tmux display-message -t "$SESSION" -p '#{session_group}' 2>/dev/null)
    if [[ -n "$_parent" && "$_parent" != "$SESSION" ]]; then
        echo "[$(ts)] Redirecting mob- target $SESSION -> $_parent" >> "$LOG"
        SESSION="$_parent"
    else
        echo "[$(ts)] WARNING: target $SESSION is a mob- session with no resolvable parent, trying anyway" >> "$LOG"
    fi
fi

log "=== Mobile attach: SESSION=$SESSION PANE=$PANE PID=$$ ==="
log "Sessions at entry:"
log_sessions

# Validate that the target session actually exists before doing anything
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
    log "ERROR: Session '$SESSION' does not exist"
    echo "Session '$SESSION' no longer exists. Available sessions:"
    tmux list-sessions -F '  #{session_name}' 2>/dev/null
    exit 1
fi

# Acquire lock BEFORE killing or creating any sessions.
# Blink opens two SSH connections per tap. The loser exits here immediately
# without touching sessions — this prevents the loser's kill loop from
# destroying the mob session the winner just created.
LOCK_FILE="/tmp/cc-notify-mobile-${SESSION}.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "LOSER: flock held by another PID — exiting duplicate (no sessions touched)"
    exit 0
fi
log "WINNER: acquired lock at $(ts)"

# We won the lock. Now kill any existing mob sessions for this parent.
# Blink keeps SSH connections alive when backgrounded, so "attached" mob
# sessions accumulate. A new deep link tap means the user wants a fresh
# connection, so we replace the old one unconditionally.
_killed=0
for s in $(tmux list-sessions -F '#{session_name} #{session_group}' 2>/dev/null \
    | awk -v parent="$SESSION" '/^mob-/ && $2 == parent {print $1}'); do
    log "Killing old mob session: $s"
    tmux kill-session -t "$s" 2>/dev/null && log "  killed $s OK" || log "  kill $s FAILED"
    (( _killed++ ))
done
log "Killed $_killed old mob session(s) for $SESSION"

# Also clean up stale mob sessions for other parents (unattached only)
for s in $(tmux list-sessions -F '#{session_name} #{session_attached}' 2>/dev/null \
    | awk '/^mob-/ && $2 == "0" {print $1}'); do
    log "Cleaning stale unattached session: $s"
    tmux kill-session -t "$s" 2>/dev/null
done

log "Sessions after cleanup:"
log_sessions

S="mob-$$"
cleanup() {
    log "=== Cleanup: killing $S ==="

    # Unzoom before killing — zoom state is window-level (shared across grouped sessions).
    # Without this, the desktop is left with a zoomed pane at mobile dimensions.
    local zoomed
    zoomed=$(tmux display-message -t "$S" -p '#{window_zoomed_flag}' 2>/dev/null || echo "0")
    log "Cleanup: window_zoomed_flag=$zoomed"
    if [[ "$zoomed" == "1" ]]; then
        log "Unzooming shared pane before kill"
        tmux resize-pane -Z -t "$S" 2>/dev/null && log "unzoom OK" || log "unzoom FAILED/skipped"
    fi

    tmux kill-session -t "$S" 2>/dev/null && log "kill-session $S OK" || log "kill-session $S FAILED/already gone"

    # Nudge desktop clients to recalculate window size now that the mobile
    # client (window-size latest) is gone. Without this the window can stay
    # at phone dimensions until the desktop client resizes itself.
    local clients
    clients=$(tmux list-clients -t "$SESSION" -F '#{client_name}' 2>/dev/null)
    log "Desktop clients to refresh: ${clients:-none}"
    echo "$clients" | while read -r _client; do
        [[ -z "$_client" ]] && continue
        tmux refresh-client -t "$_client" 2>/dev/null && log "refresh-client $_client OK" || log "refresh-client $_client FAILED"
    done
    log "=== Cleanup done ==="
}
trap cleanup EXIT

log "Pinning $SESSION to window-size largest"
tmux set -t "$SESSION" window-size largest 2>>"$LOG" && log "window-size largest OK" || log "window-size largest FAILED"
_ws=$(tmux show-option -t "$SESSION" -v window-size 2>/dev/null)
log "  verified: window-size=$_ws"

log "Creating grouped session $S -> $SESSION"
if ! tmux new-session -d -t "$SESSION" -s "$S" 2>>"$LOG"; then
    log "FAILED to create grouped session, falling back to direct attach"
    trap - EXIT
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
        log "ERROR: Session '$SESSION' died before attach"
        echo "Session '$SESSION' no longer exists."
        exit 1
    fi
    tmux attach -t "$SESSION"
    exit
fi
log "Grouped session $S created OK"

# Release the lock now — the establishment race is over.
# Holding it for the full session lifetime would block future taps while
# Blink keeps this SSH connection alive in the background.
flock -u 200
log "Lock released (establishment complete)"

log "Sessions after new-session:"
log_sessions

log "Setting $S window-size latest"
tmux set -t "$S" window-size latest 2>>"$LOG" && log "window-size latest OK" || log "window-size latest FAILED"
_ws=$(tmux show-option -t "$S" -v window-size 2>/dev/null)
log "  verified: window-size=$_ws"

log "Setting $S status off"
tmux set -t "$S" status off 2>>"$LOG" && log "status off OK" || log "status off FAILED"

if [[ -n "$PANE" ]]; then
    log "Selecting pane $PANE on $S"
    tmux select-pane -t "$S:.$PANE" 2>>"$LOG" && log "select-pane OK" || log "select-pane FAILED"

    # Zoom after a short sleep so the phone's terminal dimensions have been
    # negotiated. client-attached fires before the SSH terminal sends its size;
    # window-size latest then resizes the window to phone dims, which cancels
    # any zoom set before that resize settles. 0.3s is enough for the XTERMINAL
    # handshake to complete while remaining imperceptible to the user.
    _zoom_cmd="sleep 0.3 && tmux select-pane -t ${S}:.${PANE} && tmux resize-pane -Z -t ${S}:.${PANE} && echo [zoom-after-sleep OK] >> ${LOG} || echo [zoom-after-sleep FAILED] >> ${LOG}"
    log "Setting client-attached hook to zoom pane $PANE (after 0.3s resize settle)"
    tmux set-hook -t "$S" client-attached \
        "run-shell '$_zoom_cmd'" \
        2>>"$LOG" && log "zoom hook set OK" || log "zoom hook set FAILED"
fi

log "Attaching to $S — handoff to tmux"
tmux attach -t "$S"
log "tmux attach returned (session ended)"
