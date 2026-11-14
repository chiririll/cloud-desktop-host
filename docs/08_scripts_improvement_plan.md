# Scripts improvement plan

Status: implemented (phases 1 to 5) in the working tree; the verification table below still has to be run in a test container. Open questions 1 and 2 were resolved by porting `--steam` and keeping `--no-log`; 3 and 4 are left open. Based on a read of `scripts/*.sh` as of 2026-11-14, including the uncommitted rewrite of `sunshine-undo-desktop.sh` that now stops KWin and Xwayland on "Stop". Items marked **unverified** are assumptions to check in a container before relying on them.

## Goals

1. Fix the bugs listed below.
2. Keep each piece of logic in one place. Today the same code is copied across three to seven files and the copies have drifted.
3. Cut start-up time and the delay a Moonlight user sees when connecting.
4. Make a crash diagnosable after systemd has restarted the stack.

Not in scope: `pve/` installer scripts, and a move to one systemd unit per component (see [Later](#later-systemd-units-per-component)).

## Problems found

| # | Problem | Where | Checked how |
|---|---|---|---|
| B1 | `pkill -x` and `pgrep -x` never match names longer than 15 characters: `cloud-desktop-host`, `kactivitymanagerd`, `polkit-kde-authentication-agent-1`, `gamescope-focus-daemon`. The warning is hidden by `2>/dev/null`. | all run, prep and undo scripts | `pgrep -x` prints "will result in zero matches" |
| B2 | `pkill -f "cloud-desktop-host/build"` does not match the installed `/usr/local/bin/cloud-desktop-host`, and does match unrelated commands such as `ninja -C cloud-desktop-host/build`. | `run*.sh` | read |
| B3 | `run.sh` always exits 0. `cleanup` ends in `exit 0`, which replaces the exit code from `die`. | `run.sh` `cleanup` | reproduced: `exit 1` through the trap returns 0 |
| B4 | Logs are truncated on every start. With `Restart=always` and `RestartSec=5` the log of a crash is gone five seconds later. `/tmp/prep-*.log` and `/tmp/gamescope.log` are the opposite: they grow forever on tmpfs. | `run.sh`, prep scripts | read |
| B5 | XWayland detection takes the first `/tmp/.X11-unix/X*`. A stale socket or gamescope's Xwayland wins over KWin's. | `run.sh`, `sunshine-prep-cmd.sh`, `sunshine-prep-desktop.sh` | read |
| B6 | `[ -S /tmp/.X11-unix/X* ]` fails with "too many arguments" when two sockets exist, so the wait loop always runs its full 10 s. | `sunshine-prep-desktop.sh` | reproduced, exit code 2 |
| B7 | Only the compositor is supervised. If Sunshine dies, the unit stays active and nobody can connect. | `run.sh`, last lines | read |
| B8 | An existing GTK `settings.ini` without `gtk-decoration-layout` is overwritten whole. | `run.sh` step 6 | read |
| B9 | "Kill twice for the stubborn ones" sends SIGTERM twice and never SIGKILL. Sockets are then removed under processes that may still be alive. | `run*.sh` | read |
| B10 | `kill_all_stack` kills every `kwin_wayland`, `plasmashell` and `pipewire` of the user and removes `wayland-*`. Run on a workstation with a KDE session, it takes that session down. | `run*.sh` | read |
| B11 | `run.sh` and most other scripts are not executable in git. The README says to run `./scripts/run.sh`. | git index | `git ls-files -s` |
| P1 | `add_ts` forks `date` for every log line. 5000 lines took 83 s on the dev machine; the fork-free version below took 0.3 s. | `run.sh` | measured |
| P2 | Fixed sleeps: at least 20 s in `run.sh`, at least 5 s in `sunshine-prep-desktop.sh`. Sunshine blocks on prep commands, so the second number is connection delay. | run and prep scripts | summed |
| P3 | `run.sh` starts KWin and Plasma at 1920x1080. The first Desktop connect replaces Plasma, and "Stop" now kills KWin and Plasma anyway. | `run.sh` steps 5 to 8 | read |
| D1 | Duplication: three run scripts share about 70% of their code; the `SetOutputMode` call exists three times, display detection three times, the Plasma environment block five times, kill lists in seven files. Drift so far: the `KDE_SESSION_VERSION` fix and the double-cleanup guard exist only in `run.sh`. | all | read |
| D2 | `sunshine-prep-cmd.sh` is not referenced by `apps.json` or `apps-desktop.json`. `gamescope-patcher.sh` sets atoms that Steam ignored (see [02_implementation_plan.md](02_implementation_plan.md)). | `scripts/` | grep |

## Order of work

Each phase can be merged and tested on its own.

| Phase | Content | Fixes |
|---|---|---|
| 1 | `lib.sh` with corrected helpers; port every script to it | B1, B2, B5, B6, B9, D1 (prep and undo scripts) |
| 2 | `run.sh`: exit code, log retention, supervision, GTK; merge the run variants | B3, B4, B7, B8, D1 (run scripts) |
| 3 | Speed: fork-free timestamps, readiness polling, base-only `run.sh` | P1, P2, P3 |
| 4 | Safety: workstation guard, narrower cleanup, temp files | B10 |
| 5 | Tooling and cleanup: shellcheck in CI, file modes, dead scripts, docs | B11, D2 |

Bug fixes that live in a helper (process matching, display detection) go into `lib.sh` first, so they are written once instead of in seven files and merged later.

## Phase 1: `scripts/lib.sh`

A sourced file, no side effects on load. Every script starts with:

```bash
SCRIPT_DIR=$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")
. "$SCRIPT_DIR/lib.sh"
```

No installer change is needed: `do_scripts` copies `scripts/` whole and the MANIFEST is built from `find scripts -type f`.

### Contents

| Helper | Purpose |
|---|---|
| `cdh_env` | Sets `XDG_RUNTIME_DIR`, `DBUS_SESSION_BUS_ADDRESS` fallback, `CDH_LOG_DIR`, `CDH_STATE_DIR=$XDG_RUNTIME_DIR/cdh`. |
| `KDE_ENV` (array) | The Plasma client environment, once: `WAYLAND_DISPLAY=wayland-0`, `XDG_SESSION_TYPE`, `QT_QPA_PLATFORM`, `QT_QPA_PLATFORMTHEME`, `XDG_CURRENT_DESKTOP`, `XDG_SESSION_DESKTOP`, `KDE_SESSION_VERSION`, `KDE_FULL_SESSION`. Used as `env "${KDE_ENV[@]}" DISPLAY="$d" plasmashell` and for `dbus-update-activation-environment`. |
| `log`, `die` | Prefix with the script name. |
| `wait_for <seconds> <command...>` | Polls every 0.1 s until the command succeeds. Replaces the `seq` loops. |
| `stop_procs [-t seconds] <name...>` | SIGTERM, poll until gone, SIGKILL what is left. |
| `x_displays`, `wait_new_x_display` | Display detection by snapshot. |
| `set_output_mode <w> <h> <fps>` | The `busctl` call to `org.gamescope.Input`. |
| `set_idle <true\|false>` | `SetIdle` on `org.gamescope.Input`: puts the compositor into idle mode (frames and `frame_done` once a second) at once instead of after the 10 s auto-idle timeout. Failure is not an error: auto-idle covers it. |
| `stop_desktop`, `stop_deck` | The two kill lists, each written once. |
| `start_desktop <w> <h>` | KWin, activation environment, kded6, plasmashell, polkit. |

### Process matching (B1, B2, B9)

The kernel keeps 15 characters of the process name, so match on the truncated name:

```bash
wait_for() {   # wait_for <seconds> <command...>
    local deadline=$((SECONDS + $1)); shift
    until "$@" 2>/dev/null; do
        if ((SECONDS >= deadline)); then return 1; fi
        sleep 0.1
    done
}
stop_procs() {
    local timeout=5 n
    if [ "$1" = -t ]; then timeout=$2; shift 2; fi
    for n in "$@"; do pkill -u "$UID" -x "${n:0:15}" 2>/dev/null || true; done
    wait_for "$timeout" _all_gone "$@" && return 0
    for n in "$@"; do pkill -KILL -u "$UID" -x "${n:0:15}" 2>/dev/null || true; done
    wait_for 2 _all_gone "$@"
}
_all_gone() {
    local n
    for n in "$@"; do pgrep -u "$UID" -x "${n:0:15}" >/dev/null && return 1; done
    return 0
}
```

Drop the `-f "cloud-desktop-host/build"` line. Keep `-f` only for `steamwebhelper`, `steam-runtime-launcher-service` and `steamclient`, where the name is part of a longer command line.

Check in a container that the truncated names match what is running: `cat /proc/<pid>/comm` for the compositor, kactivitymanagerd and the polkit agent (**unverified**).

### Display detection (B5, B6)

Take a snapshot of the X sockets before KWin starts and wait for a new one:

```bash
x_displays() {
    local s
    for s in /tmp/.X11-unix/X*; do
        if [ -S "$s" ]; then echo "${s##*X}"; fi
    done
}
wait_new_x_display() {   # $1 = displays before (space separated), $2 = timeout in seconds
    local before=" $1 " n i
    for ((i = 0; i < $2 * 10; i++)); do
        for n in $(x_displays); do
            if [[ $before != *" $n "* ]]; then echo ":$n"; return 0; fi
        done
        sleep 0.1
    done
    return 1
}
```

`start_desktop` writes the result to `$CDH_STATE_DIR/kwin-display`. Scripts that find KWin already running read that file instead of guessing. `stop_desktop` removes it.

Stale sockets: replace the hard-coded `rm -f /tmp/.X0-lock ... X2` with a loop over `/tmp/.X*-lock` that removes a lock and its socket only when the PID inside the lock file is dead.

### Scripts after the port

| Script | Becomes |
|---|---|
| `sunshine-prep-desktop.sh` | `stop_deck`, `set_output_mode`, `start_desktop` |
| `sunshine-undo-desktop.sh` | `stop_desktop` (Plasma, Steam, KWin with its 5 s grace period, Xwayland), as in the current working-tree version, then `set_idle true` |
| `sunshine-prep-gamescope.sh` | binary checks, `stop_desktop`, `stop_deck`, `set_output_mode`, MangoHud config, gamescope launch |
| `sunshine-undo-gamescope.sh` | `stop_deck`, then `set_idle true` |

Prep and undo scripts use `set -u` but not `set -e`. A failed `pkill` must not abort a prep command, because Sunshine cancels the launch when a prep command returns non-zero. Real failures (`set_output_mode`, missing binary, gamescope exits at once) return a non-zero code explicitly.

## Phase 2: `run.sh`

### Exit code (B3)

```bash
cleanup() {
    local rc=$?
    trap - EXIT INT TERM
    ...
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 0' INT TERM    # a requested stop is a success
```

A failed start then shows as failed in `systemctl --user status`. `Restart=always` restarts in both cases, so behaviour under systemd does not change otherwise.

### Log retention (B4)

- One directory per start: `/tmp/cdhost-logs/<YYYYmmdd-HHMMSS>/`, plus a `latest` symlink. Keep the newest five, delete older ones at start. The installer hint "logs in `/tmp/cdhost-logs/`" stays correct.
- `run.sh` exports `CDH_LOG_DIR`. Prep and undo scripts write `prep-desktop.log`, `prep-gamescope.log`, `gamescope.log` and `plasmashell.log` there, so they rotate with the rest. This relies on Sunshine passing its environment to prep commands, which the scripts already depend on for `DBUS_SESSION_BUS_ADDRESS` (**unverified**; fall back to `/tmp/cdhost-logs/latest` when the variable is unset).

### Supervision (B7)

KWin and Plasma are stopped on purpose by `sunshine-undo-desktop.sh`, so they must not count as a failure. The long-lived processes are the compositor and Sunshine:

```bash
rc=0
wait -n -p dead "$HOST_PID" "$SUNSHINE_PID" || rc=$?
log "PID $dead exited with status $rc; stopping the stack"
exit $(( rc ? rc : 1 ))
```

`wait -n -p` needs bash 5.1; Fedora 43 has 5.3. Check that "Restart" in the Sunshine web UI does not exit the watched PID (**unverified**). If it does, either watch only the compositor and restart Sunshine in a loop, or accept the full stack restart.

### GTK settings (B8)

Create `settings.ini` only when it is missing. When it exists without the key, insert the line after `[Settings]` with `sed` instead of rewriting the file. This step moves into `start_desktop` in phase 3.

### One run script (D1)

```
run.sh [--no-log] [--steam] [hud] [debug] [-- <compositor arguments>]
```

- `--no-log`: children write to `/dev/null`, the compositor still writes one log file. Replaces `run-nolog.sh`.
- `--steam`: standalone Steam GamepadUI on a full-screen Xwayland, no KWin. Replaces `run-steam.sh`.
- `hud`, `debug`: the shorthands `run-nolog.sh` accepts today.

Delete `run-nolog.sh` and `run-steam.sh` and update the README. Once timestamps are cheap (phase 3), check whether `--no-log` still changes CPU load; if not, drop the flag.

## Phase 3: speed

### Fork-free timestamps (P1)

```bash
add_ts() {
    local line us
    while IFS= read -r line; do
        us=${EPOCHREALTIME#*[.,]}
        printf '[%(%H:%M:%S)T.%s] %s\n' -1 "${us:0:3}" "$line"
    done
}
```

Same output format as today. `[.,]` covers locales with a decimal comma.

### Readiness polling (P2)

| Today | Replace with |
|---|---|
| `sleep 1` twice around `kill_all_stack` | `stop_procs` returns when the processes are gone |
| `sleep 1` after `pipewire` | `wait_for 5 test -S "$XDG_RUNTIME_DIR/pipewire-0"` |
| `sleep 1` after `wireplumber` | nothing; nothing depends on it at start |
| `sleep 1` after `pipewire-pulse` | `wait_for 5 test -S "$XDG_RUNTIME_DIR/pulse/native"` |
| `sleep 1` after `kactivitymanagerd` | nothing; report its state in the final summary |
| 1 s polling for `wayland-cd` | 0.1 s polling, then `wait_for 5 busctl --user status org.gamescope.Input`, because prep scripts need the D-Bus name |
| `sleep 3` plus loop after KWin | `wait_new_x_display` |
| `sleep 2` after `kded6` | `wait_for 5 busctl --user status org.kde.kded6` |
| `sleep 5` after `plasmashell` | `wait_for 15 busctl --user status org.kde.plasmashell` |
| `sleep 1` after polkit, `sleep 3` after Sunshine | one liveness check after 1 s |
| `sleep 1` after `pkill` in prep scripts | `stop_procs` |
| `sleep 0.5` after `SetOutputMode` | keep; there is no cheap signal that the mode was applied |

Log the elapsed time at the end of `run.sh` and of each prep script (`$SECONDS`), and record the numbers before and after this phase.

### Base-only `run.sh` (P3)

`run.sh` starts D-Bus, PipeWire, kactivitymanagerd, the compositor and Sunshine, and nothing else. KWin and Plasma are started by `sunshine-prep-desktop.sh` through `start_desktop`, at the client's resolution. This is what `run-nolog.sh` does today, and it matches the new `sunshine-undo-desktop.sh`, which leaves no desktop running after "Stop". The hard-coded 1920x1080 disappears.

Effect to accept: the first Desktop connect after boot starts KWin and Plasma instead of finding them running. With polling this should cost a few seconds; measure it.

## Phase 4: safety

1. **Workstation guard (B10).** `run.sh` refuses to start when `WAYLAND_DISPLAY` or `DISPLAY` is set in its environment, unless `CDH_FORCE=1`. The systemd unit in the container has neither. A manual restart from a terminal inside the streamed desktop has `WAYLAND_DISPLAY=wayland-0` and will need the override.
2. **Narrower cleanup.** Remove `wayland-*`, `pipewire-*` and `pulse/native` only after `stop_procs` reports that their owners are gone. On exit remove only `wayland-cd*`.
3. **D-Bus daemon.** When `run.sh` launched the bus itself, kill `$DBUS_SESSION_BUS_PID` in `cleanup`. Quote the `eval`: `eval "$(dbus-launch --sh-syntax)"`.
4. **Temp files.** Move `mangohud-gamescope.conf` and the display state file to `$CDH_STATE_DIR` (`$XDG_RUNTIME_DIR/cdh`, mode 700).
5. **Binary fallback.** Replace `/home/user/cloud-desktop-host/build/...` with `$SCRIPT_DIR/../build/cloud-desktop-host`. Same for the gamescope fallback path.

## Phase 5: tooling and cleanup

1. **CI.** New workflow on push and pull request: `bash -n` and `shellcheck -x scripts/*.sh`. Fix or annotate what it reports.
2. **File modes (B11).** `git update-index --chmod=+x` for every entry-point script. `lib.sh` stays non-executable in git.
3. **Dead scripts (D2).** Delete `sunshine-prep-cmd.sh`. Move `gamescope-patcher.sh` to `tools/` so it is not shipped into containers.
4. **Stale files in containers.** `do_scripts` extracts over the existing directory and does not delete files that left the repository. Deleted scripts stay in `/opt/cloud-desktop-host/scripts` on upgraded containers. Either clear `scripts/` before extracting or leave it; this is an installer change and needs `pve/build.sh` to be rerun.
5. **Docs.** README script tree and quick start, [APP_ARCHITECTURE.md](APP_ARCHITECTURE.md) section 5.6. Documents 01 to 05 are history and stay as they are.

## Verification

Run in a test container after each phase.

| Check | Expected |
|---|---|
| `bash -n scripts/*.sh`, `shellcheck -x scripts/*.sh` | clean |
| `pve/install.sh --check` | passes; MANIFEST lists `scripts/lib.sh` |
| Cold start under systemd | unit active; elapsed time logged and lower than before |
| Rename the compositor binary, start the unit | unit shows a failed start, not success |
| `kill` the compositor | stack restarts; the previous log directory is still there |
| `kill` Sunshine | stack restarts |
| Moonlight: Desktop, then Stop | KWin, Plasma and Xwayland gone; compositor, PipeWire and Sunshine still running; compositor log shows `[idle] ON (D-Bus SetIdle)` |
| Moonlight: connect after Stop | compositor log shows `[idle] OFF (SetOutputMode)` before KWin starts |
| Moonlight: Desktop again | desktop comes up at the client resolution; prep time logged |
| Moonlight: Steam Deck Mode, Stop, then Desktop | each switch works; no leftover `gamescope`, `steam` or `Xwayland` |
| Manual `run.sh`, then Ctrl+C | `pgrep -u "$UID" -a` shows none of the stack's processes |
| Manual `run.sh` inside a KDE session | refuses to start without `CDH_FORCE=1` |

## Open questions

1. Is `run-steam.sh` (standalone Steam without gamescope) still used? If not, delete it instead of porting it to `run.sh --steam`.
2. Keep `--no-log` after phase 3, or is cheap logging enough?
3. Should the unit keep `UnsetEnvironment=DBUS_SESSION_BUS_ADDRESS` and a private `dbus-launch` bus? The prep scripts fall back to the systemd user bus at `/run/user/<uid>/bus`, which is a different bus from the one the compositor registers on. Either remove the fallback or move the stack to the user bus. The same fallback is used by the `SetIdle` call in the undo scripts; there a wrong bus only delays idle by 10 s.
4. Stale files in upgraded containers (phase 5, item 4): clean up or leave?

## Later: systemd units per component

One user unit per process (`cdh-compositor`, `cdh-sunshine`, `cdh-kwin`, `cdh-plasma`, `cdh-gamescope`) with `BindsTo=` and `After=` for ordering, and two targets, `cdh-desktop.target` and `cdh-deck.target`, that declare `Conflicts=` on each other. Prep and undo scripts shrink to `systemctl --user start` and `stop`. This removes the kill lists, the polling and the log plumbing, and gives per-component restart and journald logs. It is a redesign of how the stack starts and needs installer changes, so it is not part of this plan.
