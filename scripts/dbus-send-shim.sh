#!/bin/bash
# dbus-send-shim.sh — the "dbus-send" a CDH session finds first in PATH (cdh_env in lib.sh links it there).
#
# Steam's power menu → Suspend (Big Picture and the Deck UI alike) is not a D-Bus call of its own but
#   steam-runtime-launch-client --alongside-steam -- dbus-send --system --print-reply \
#       --dest=org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager.Suspend boolean:true
# run with the PATH Steam was started with. logind in a container answers "sleep verb not supported" before it
# even asks polkit, so nothing on the system side can catch it, and Steam shows the button regardless.
# A sleep request to logind therefore goes to session-action.sh suspend; any other call runs the real dbus-send.

SELF=$(readlink -f "${BASH_SOURCE[0]}")

for arg in "$@"; do
    case "$arg" in
        org.freedesktop.login1.Manager.Suspend | org.freedesktop.login1.Manager.Hibernate | \
        org.freedesktop.login1.Manager.HybridSleep | org.freedesktop.login1.Manager.SuspendThenHibernate | \
        org.freedesktop.login1.Manager.Sleep)
            # Detached: the action stops the session, and with it the launcher service we are a child of
            setsid -f "${SELF%/*}/session-action.sh" suspend </dev/null >/dev/null 2>&1
            exit 0
            ;;
    esac
done

mapfile -t candidates < <(type -aP dbus-send)
for bin in "${candidates[@]}"; do
    if [ "$(readlink -f "$bin")" != "$SELF" ]; then exec "$bin" "$@"; fi
done
echo "dbus-send: no dbus-send in PATH behind ${BASH_SOURCE[0]}" >&2
exit 127
