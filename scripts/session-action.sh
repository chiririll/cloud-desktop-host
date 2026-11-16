#!/bin/bash
# session-action.sh — what Plasma's Log out / Restart / Shut down and Steam's Suspend do in a CDH session.
# Run by "cloud-desktop-host --kde-shutdown", which the session bus starts for org.kde.Shutdown calls
# (src/session.cpp; the .service file is written by run.sh), and for suspend by dbus-send-shim.sh.
#
# Usage: session-action.sh logout|suspend|reboot|shutdown
#   logout    end the Moonlight stream: the Desktop app's placeholder (sunshine-desktop-hold.sh) exits,
#             Sunshine closes the stream and runs sunshine-undo-desktop.sh
#   suspend   same as logout: a container cannot sleep, a stopped session is what burns no CPU/GPU
#   reboot    restart the whole CDH stack (cloud-desktop-host.service); the client reconnects
#   shutdown  power off the container (polkit rule from ct-install.sh: 50-cdh-power.rules)

set -u
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"
cdh_env
mkdir -p "$CDH_LOG_DIR"
exec >>"$CDH_LOG_DIR/session-action.log" 2>&1
printf '=== %(%F %T)T %s ===\n' -1 "${1:-}"

SESSION_UNIT=cloud-desktop-host.service

end_stream() {
    # the script's own process (shebang → "/bin/bash <path>"), not an editor that has it open
    if pkill -TERM -u "$UID" -f -- '^(/usr)?/bin/bash [^ ]*/sunshine-desktop-hold\.sh$'; then
        log "Desktop app placeholder stopped: Sunshine ends the stream"
        return 0
    fi
    # Steam Deck Mode (its Sunshine app has no placeholder), an apps.json edited by hand, or no stream at all
    log "no Desktop app placeholder running: stopping the session, a connected client stays on an empty screen"
    if pgrep -u "$UID" -x gamescope >/dev/null; then
        "$SCRIPT_DIR/sunshine-undo-gamescope.sh"
    else
        "$SCRIPT_DIR/sunshine-undo-desktop.sh"
    fi
}

case "${1:-}" in
    logout | suspend)
        end_stream
        ;;
    reboot)
        if systemctl --user is-active -q "$SESSION_UNIT"; then
            log "restarting $SESSION_UNIT"
            systemctl --user --no-block restart "$SESSION_UNIT"
        else
            log "$SESSION_UNIT is not running (run.sh started by hand?): only ending the stream"
            end_stream
        fi
        ;;
    shutdown)
        log "powering off the container"
        systemctl poweroff --no-ask-password \
            || log "poweroff refused: is /etc/polkit-1/rules.d/50-cdh-power.rules installed (ct-install.sh)?"
        ;;
    *)
        die "usage: ${0##*/} logout|suspend|reboot|shutdown"
        ;;
esac
