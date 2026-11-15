/*
 * cloud-desktop-host — session.cpp
 * `cloud-desktop-host --kde-shutdown <action>`: org.kde.Shutdown /Shutdown, what Plasma calls for
 * Log out / Restart / Shut down (directly, or from ksmserver-logout-greeter after its confirmation dialog).
 *
 * CDH starts KWin and plasmashell itself, without ksmserver/plasma_session, so Plasma's own
 * plasma-shutdown has no session to close and every button does nothing.
 *
 * The name must NOT be owned all the time: ksmserver-logout-greeter quits at start when org.kde.Shutdown
 * already has an owner ("a logout is in progress"). So this is a D-Bus activated one-shot: run.sh puts an
 * org.kde.Shutdown.service in front of Plasma's (XDG_DATA_DIRS of the session bus), the bus starts us on
 * the first call, we answer it, run `<action> logout|reboot|shutdown` (scripts/session-action.sh), exit.
 */
#define _POSIX_C_SOURCE 200809L

#include "session.h"

extern "C" {
#include <wlr/util/log.h>
}

#include <systemd/sd-bus.h>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>

static constexpr const char *kName = "org.kde.Shutdown";
static constexpr uint64_t kIdleTimeoutUsec = 30ull * 1000 * 1000;   // activated but never called

static const char *s_verb = nullptr;   // set by the first method call

/* Double fork: the action (which may restart our session) is not our child. */
static void run_action(const char *action, const char *verb) {
    wlr_log(WLR_INFO, "[kde-shutdown] %s %s", action, verb);
    pid_t pid = fork();
    if (pid < 0) {
        wlr_log(WLR_ERROR, "[kde-shutdown] fork failed: %s", strerror(errno));
        return;
    }
    if (pid == 0) {
        if (fork() != 0) _exit(0);
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, nullptr);
        setsid();
        execl(action, action, verb, (char *)nullptr);
        _exit(127);
    }
    while (waitpid(pid, nullptr, 0) < 0 && errno == EINTR) {}
}

static int take(sd_bus_message *m, const char *verb) {
    if (!s_verb) s_verb = verb;   // a second call before we exit is answered and ignored
    return sd_bus_reply_method_return(m, "");
}
static int method_logout(sd_bus_message *m, void *, sd_bus_error *)   { return take(m, "logout"); }
static int method_shutdown(sd_bus_message *m, void *, sd_bus_error *) { return take(m, "shutdown"); }
static int method_reboot(sd_bus_message *m, void *, sd_bus_error *)   { return take(m, "reboot"); }

static const sd_bus_vtable s_vtable[] = {
    SD_BUS_VTABLE_START(0),
    SD_BUS_METHOD("logout", "", "", method_logout, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("logoutAndShutdown", "", "", method_shutdown, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_METHOD("logoutAndReboot", "", "", method_reboot, SD_BUS_VTABLE_UNPRIVILEGED),
    SD_BUS_SIGNAL("logoutCancelled", "", 0),
    SD_BUS_SIGNAL("logoutComplete", "", 0),
    SD_BUS_VTABLE_END,
};

int cd_kde_shutdown_main(const char *action) {
    if (!action || access(action, X_OK) != 0) {
        wlr_log(WLR_ERROR, "[kde-shutdown] usage: --kde-shutdown <executable action script>");
        return 2;
    }

    sd_bus *bus = nullptr;
    sd_bus_slot *slot = nullptr;
    int r = sd_bus_open_user(&bus);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[kde-shutdown] session bus: %s", strerror(-r));
        return 1;
    }
    r = sd_bus_add_object_vtable(bus, &slot, "/Shutdown", kName, s_vtable, nullptr);
    if (r >= 0) r = sd_bus_request_name(bus, kName, 0);
    if (r < 0) {
        wlr_log(WLR_ERROR, "[kde-shutdown] cannot serve %s: %s", kName, strerror(-r));
        sd_bus_slot_unref(slot);
        sd_bus_unref(bus);
        return 1;
    }

    /* Serve until the first call (the bus queued it for us during activation) or the idle timeout */
    while (!s_verb) {
        r = sd_bus_process(bus, nullptr);
        if (r < 0) break;
        if (r > 0) continue;
        r = sd_bus_wait(bus, kIdleTimeoutUsec);
        if (r <= 0) break;   // error or timeout
    }
    sd_bus_flush(bus);   // the reply goes out before the action can tear the session down
    sd_bus_release_name(bus, kName);
    sd_bus_slot_unref(slot);
    sd_bus_flush_close_unref(bus);

    if (!s_verb) {
        wlr_log(WLR_INFO, "[kde-shutdown] activated but not called, exiting");
        return 0;
    }
    run_action(action, s_verb);
    return 0;
}
