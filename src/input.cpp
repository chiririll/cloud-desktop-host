/*
 * cloud-desktop-host — input.cpp
 * Обработка ввода через либ-инпут (standalone).
 */
#include "server.h"
extern "C" {
#include <wlr/util/log.h>
}
#include <libinput.h>
#include <libudev.h>
#include <unistd.h>
#include <fcntl.h>
#include <dirent.h>
#include <stdlib.h>
#include <string.h>
#include <sys/inotify.h>
#include <linux/input-event-codes.h>
#include <fstream>
#include <map>
#include <string>

/*
 * ── Input backends ──
 *
 * udev: libinput_udev_* + seat0. Needs udev hotplug events, which an
 *       unprivileged LXC container does not receive (its network namespace
 *       is owned by a non-initial user namespace, so kernel uevents are not
 *       delivered and systemd-udevd cannot run). Sunshine's virtual devices,
 *       created on connect, would never be seen.
 *
 * path: libinput_path_* + inotify on /dev/input. Works without udev events.
 *       libinput still reads device properties (ID_INPUT_*) from the udev
 *       database, so /run/udev of the host must be bind-mounted read-only.
 *
 * Selection: CDH_INPUT_BACKEND=udev|path, otherwise path inside a user
 * namespace and udev everywhere else.
 */
namespace {

constexpr const char *INPUT_DIR         = "/dev/input";
constexpr int         RETRY_INTERVAL_MS = 100;
constexpr int         RETRY_ATTEMPTS    = 30;   /* 3 s: wait for host udev to chown + write db */

struct path_backend {
    bool                                          active = false;
    int                                           inotify_fd = -1;
    struct wl_event_source                       *inotify_source = nullptr;
    struct wl_event_source                       *retry_timer = nullptr;
    std::map<std::string, struct libinput_device*> devices;   /* sysname → device, holds a ref */
    std::map<std::string, int>                     pending;   /* sysname → attempts left */
};

path_backend g_path;

bool is_event_node(const char *name) {
    return strncmp(name, "event", 5) == 0;
}

} // namespace

/* ── Интерфейс для libinput ── */
static int open_restricted(const char *path, int flags, [[maybe_unused]] void *user_data) {
    return open(path, flags);
}
static void close_restricted(int fd, [[maybe_unused]] void *user_data) {
    close(fd);
}
static const struct libinput_interface li_iface = {
    .open_restricted = open_restricted,
    .close_restricted = close_restricted,
};

/* ── Обработка событий libinput ── */

static void handle_pointer_motion(struct cd_server *server,
                                  struct libinput_event_pointer *pe) {
    clock_gettime(CLOCK_MONOTONIC, &server->last_mouse_activity_time);
    double dx = libinput_event_pointer_get_dx(pe);
    double dy = libinput_event_pointer_get_dy(pe);
    uint32_t time = libinput_event_pointer_get_time(pe);

    server->hud_mouse_dx = dx;
    server->hud_mouse_dy = dy;

    /* Абсолютная позиция — только для поддержания фокуса в FREE-режиме */
    server->cursor_x += dx;
    server->cursor_y += dy;
    if (server->cursor_x < 0) server->cursor_x = 0;
    if (server->cursor_y < 0) server->cursor_y = 0;
    if (server->cursor_x >= server->cur_width)  server->cursor_x = server->cur_width - 1;
    if (server->cursor_y >= server->cur_height) server->cursor_y = server->cur_height - 1;

    if (!server->has_active_constraint) {
        struct wlr_surface *focused = server->seat->pointer_state.focused_surface;
        if (!focused && server->desktop_surface) {
            wlr_seat_pointer_notify_enter(server->seat, server->desktop_surface,
                server->cursor_x, server->cursor_y);
        }
        wlr_seat_pointer_notify_motion(server->seat, time,
            server->cursor_x, server->cursor_y);
    }

    /* Relative motion — прямая передача ускорений в KWin */
    if (server->relative_pointer_mgr) {
        uint64_t time_usec = (uint64_t)libinput_event_pointer_get_time_usec(pe);
        double dx_unaccel = libinput_event_pointer_get_dx_unaccelerated(pe);
        double dy_unaccel = libinput_event_pointer_get_dy_unaccelerated(pe);
        wlr_relative_pointer_manager_v1_send_relative_motion(
            server->relative_pointer_mgr, server->seat,
            time_usec, dx, dy, dx_unaccel, dy_unaccel);
    }

    wlr_seat_pointer_notify_frame(server->seat);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

static void handle_pointer_motion_abs(struct cd_server *server,
                                      struct libinput_event_pointer *pe) {
    double x = libinput_event_pointer_get_absolute_x_transformed(pe, server->cur_width);
    double y = libinput_event_pointer_get_absolute_y_transformed(pe, server->cur_height);
    uint32_t time = libinput_event_pointer_get_time(pe);

    server->cursor_x = x;
    server->cursor_y = y;
    clock_gettime(CLOCK_MONOTONIC, &server->last_mouse_activity_time);

    /* KWin's nested Wayland backend accepts absolute wl_pointer.motion even
     * while the host pointer lock is active, so no conversion to relative
     * motion is needed (and no second cursor position can drift). */
    struct wlr_surface *focused = server->seat->pointer_state.focused_surface;
    if (!focused && server->desktop_surface) {
        wlr_seat_pointer_notify_enter(server->seat, server->desktop_surface, x, y);
    }
    wlr_seat_pointer_notify_motion(server->seat, time, x, y);

    wlr_seat_pointer_notify_frame(server->seat);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

static void handle_pointer_button(struct cd_server *server,
                                  struct libinput_event_pointer *pe) {
    uint32_t button = libinput_event_pointer_get_button(pe);
    uint32_t time = libinput_event_pointer_get_time(pe);
    enum libinput_button_state state = libinput_event_pointer_get_button_state(pe);

    enum wl_pointer_button_state wl_state =
        (state == LIBINPUT_BUTTON_STATE_PRESSED)
            ? WL_POINTER_BUTTON_STATE_PRESSED : WL_POINTER_BUTTON_STATE_RELEASED;

    wlr_seat_pointer_notify_button(server->seat, time, button, wl_state);
    wlr_seat_pointer_notify_frame(server->seat);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

static double get_scroll_factor(struct cd_server *server,
                                 struct libinput_event_pointer *pe) {
    struct libinput_event *base = libinput_event_pointer_get_base_event(pe);
    struct libinput_device *dev = libinput_event_get_device(base);
    const char *sysname = libinput_device_get_sysname(dev);
    return cd_dbus_input_get_scroll_factor(&server->dbus_input, sysname);
}

static void handle_scroll_wheel(struct cd_server *server,
                                struct libinput_event_pointer *pe) {
    uint32_t time = libinput_event_pointer_get_time(pe);
    double factor = get_scroll_factor(server, pe);

    if (libinput_event_pointer_has_axis(pe, LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL)) {
        double v120 = libinput_event_pointer_get_scroll_value_v120(
            pe, LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL);
        double value = (v120 / 120.0) * factor * 15.0; // Примерный коэффициент
        wlr_seat_pointer_notify_axis(server->seat, time,
            WL_POINTER_AXIS_VERTICAL_SCROLL, value, (int32_t)v120,
            WL_POINTER_AXIS_SOURCE_WHEEL, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(server->seat);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

static void handle_scroll_continuous(struct cd_server *server,
                                     struct libinput_event_pointer *pe,
                                     enum wl_pointer_axis_source source) {
    uint32_t time = libinput_event_pointer_get_time(pe);
    double factor = get_scroll_factor(server, pe);

    if (libinput_event_pointer_has_axis(pe, LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL)) {
        double value = libinput_event_pointer_get_scroll_value(
            pe, LIBINPUT_POINTER_AXIS_SCROLL_VERTICAL) * factor;
        wlr_seat_pointer_notify_axis(server->seat, time,
            WL_POINTER_AXIS_VERTICAL_SCROLL, value, 0,
            source, WL_POINTER_AXIS_RELATIVE_DIRECTION_IDENTICAL);
    }
    wlr_seat_pointer_notify_frame(server->seat);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

static void handle_keyboard_key(struct cd_server *server,
                                struct libinput_event_keyboard *ke) {
    uint32_t key = libinput_event_keyboard_get_key(ke);
    uint32_t time = libinput_event_keyboard_get_time(ke);
    enum libinput_key_state state = libinput_event_keyboard_get_key_state(ke);

    uint32_t wl_state =
        (state == LIBINPUT_KEY_STATE_PRESSED)
            ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED;

    wlr_seat_keyboard_notify_key(server->seat, time, key, wl_state);

    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

/* ── Dispatch всех событий libinput ── */
static void dispatch_libinput(struct cd_server *server, struct libinput *li) {
    libinput_dispatch(li);

    struct libinput_event *event;
    while ((event = libinput_get_event(li)) != nullptr) {
        enum libinput_event_type type = libinput_event_get_type(event);

        switch (type) {
        case LIBINPUT_EVENT_POINTER_MOTION:
            handle_pointer_motion(server,
                libinput_event_get_pointer_event(event));
            break;
        case LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE:
            handle_pointer_motion_abs(server,
                libinput_event_get_pointer_event(event));
            break;
        case LIBINPUT_EVENT_POINTER_BUTTON:
            handle_pointer_button(server,
                libinput_event_get_pointer_event(event));
            break;
        case LIBINPUT_EVENT_POINTER_SCROLL_WHEEL:
            handle_scroll_wheel(server,
                libinput_event_get_pointer_event(event));
            break;
        case LIBINPUT_EVENT_POINTER_SCROLL_FINGER:
            handle_scroll_continuous(server,
                libinput_event_get_pointer_event(event),
                WL_POINTER_AXIS_SOURCE_FINGER);
            break;
        case LIBINPUT_EVENT_POINTER_SCROLL_CONTINUOUS:
            handle_scroll_continuous(server,
                libinput_event_get_pointer_event(event),
                WL_POINTER_AXIS_SOURCE_CONTINUOUS);
            break;
        case LIBINPUT_EVENT_KEYBOARD_KEY:
            handle_keyboard_key(server,
                libinput_event_get_keyboard_event(event));
            break;
        case LIBINPUT_EVENT_DEVICE_ADDED:
            cd_dbus_input_device_added(&server->dbus_input, libinput_event_get_device(event));
            break;
        case LIBINPUT_EVENT_DEVICE_REMOVED: {
            struct libinput_device *dev = libinput_event_get_device(event);
            cd_dbus_input_device_removed(&server->dbus_input, dev);
            if (g_path.active) {
                /* libinput drops a device itself on ENODEV — forget it here too */
                auto it = g_path.devices.find(libinput_device_get_sysname(dev));
                if (it != g_path.devices.end() && it->second == dev) {
                    g_path.devices.erase(it);
                    libinput_device_unref(dev);
                }
            }
            break;
        }
        default:
            break;
        }
        libinput_event_destroy(event);
    }
}

static int libinput_event_cb(int fd, uint32_t mask, void *data) {
    (void)fd; (void)mask;
    auto *server = static_cast<struct cd_server*>(data);
    if (server->libinput_ctx) dispatch_libinput(server, server->libinput_ctx);
    return 0;
}

/* ── Path backend: hotplug via inotify ── */

static bool path_try_add(struct cd_server *server, const std::string &name) {
    if (g_path.devices.count(name)) return true;

    std::string path = std::string(INPUT_DIR) + "/" + name;
    if (access(path.c_str(), R_OK) != 0) return false;   /* not ours / not chowned yet */

    /* NULL also when the udev db has no ID_INPUT yet — retried by the timer */
    struct libinput_device *dev = libinput_path_add_device(server->libinput_ctx, path.c_str());
    if (!dev) return false;

    libinput_device_ref(dev);
    g_path.devices[name] = dev;
    wlr_log(WLR_INFO, "[input/path] added %s (%s)", path.c_str(), libinput_device_get_name(dev));
    dispatch_libinput(server, server->libinput_ctx);       /* deliver DEVICE_ADDED → D-Bus */
    return true;
}

static void path_process_pending(struct cd_server *server) {
    for (auto it = g_path.pending.begin(); it != g_path.pending.end();) {
        if (path_try_add(server, it->first)) {
            it = g_path.pending.erase(it);
        } else if (--it->second <= 0) {
            wlr_log(WLR_DEBUG, "[input/path] giving up on %s/%s (not accessible or not an input device)",
                    INPUT_DIR, it->first.c_str());
            it = g_path.pending.erase(it);
        } else {
            ++it;
        }
    }
    if (!g_path.pending.empty())
        wl_event_source_timer_update(g_path.retry_timer, RETRY_INTERVAL_MS);
}

static void path_schedule(struct cd_server *server, const std::string &name) {
    if (g_path.devices.count(name)) return;
    g_path.pending[name] = RETRY_ATTEMPTS;
    path_process_pending(server);
}

static void path_remove(struct cd_server *server, const std::string &name) {
    g_path.pending.erase(name);
    auto it = g_path.devices.find(name);
    if (it == g_path.devices.end()) return;

    struct libinput_device *dev = it->second;
    g_path.devices.erase(it);
    wlr_log(WLR_INFO, "[input/path] removed %s/%s", INPUT_DIR, name.c_str());
    libinput_path_remove_device(dev);
    libinput_device_unref(dev);
    dispatch_libinput(server, server->libinput_ctx);       /* deliver DEVICE_REMOVED → D-Bus */
}

static void path_rescan(struct cd_server *server) {
    DIR *dir = opendir(INPUT_DIR);
    if (!dir) {
        wlr_log_errno(WLR_ERROR, "[input/path] cannot open %s", INPUT_DIR);
        return;
    }
    while (struct dirent *de = readdir(dir)) {
        if (is_event_node(de->d_name) && !g_path.devices.count(de->d_name))
            g_path.pending[de->d_name] = RETRY_ATTEMPTS;
    }
    closedir(dir);
    path_process_pending(server);
}

static int path_inotify_cb(int fd, uint32_t mask, void *data) {
    (void)mask;
    auto *server = static_cast<struct cd_server*>(data);
    alignas(struct inotify_event) char buf[4096];

    for (;;) {
        ssize_t len = read(fd, buf, sizeof(buf));
        if (len <= 0) break;   /* EAGAIN — drained */

        for (char *p = buf; p < buf + len;) {
            auto *ev = reinterpret_cast<struct inotify_event*>(p);
            p += sizeof(struct inotify_event) + ev->len;

            if (ev->mask & IN_Q_OVERFLOW) {
                path_rescan(server);
                continue;
            }
            if (!ev->len || !is_event_node(ev->name)) continue;

            if (ev->mask & (IN_DELETE | IN_MOVED_FROM))
                path_remove(server, ev->name);
            else if (ev->mask & (IN_CREATE | IN_ATTRIB | IN_MOVED_TO))
                path_schedule(server, ev->name);   /* ATTRIB = host udev chown'ed it */
        }
    }
    return 0;
}

static int path_retry_cb(void *data) {
    path_process_pending(static_cast<struct cd_server*>(data));
    return 0;
}

static bool setup_path_backend(struct cd_server *server, struct wl_event_loop *loop) {
    struct libinput *li = libinput_path_create_context(&li_iface, server);
    if (!li) {
        wlr_log(WLR_ERROR, "[input/path] libinput_path_create_context failed");
        return false;
    }
    server->libinput_ctx = li;
    server->udev_ctx = nullptr;
    g_path.active = true;

    g_path.inotify_fd = inotify_init1(IN_NONBLOCK | IN_CLOEXEC);
    if (g_path.inotify_fd < 0 ||
        inotify_add_watch(g_path.inotify_fd, INPUT_DIR,
                          IN_CREATE | IN_ATTRIB | IN_DELETE | IN_MOVED_TO | IN_MOVED_FROM) < 0) {
        wlr_log_errno(WLR_ERROR, "[input/path] inotify on %s failed — hotplug disabled", INPUT_DIR);
    } else {
        g_path.inotify_source = wl_event_loop_add_fd(
            loop, g_path.inotify_fd, WL_EVENT_READABLE, path_inotify_cb, server);
    }
    g_path.retry_timer = wl_event_loop_add_timer(loop, path_retry_cb, server);

    if (access("/run/udev/data", R_OK) != 0)
        wlr_log(WLR_ERROR, "[input/path] /run/udev/data not readable — libinput will ignore "
                           "devices; bind-mount the host's /run/udev read-only");

    path_rescan(server);
    return true;
}

static bool setup_udev_backend(struct cd_server *server) {
    struct udev *udev = udev_new();
    if (!udev) {
        wlr_log(WLR_ERROR, "[input/udev] udev_new failed");
        return false;
    }
    struct libinput *li = libinput_udev_create_context(&li_iface, server, udev);
    if (!li || libinput_udev_assign_seat(li, "seat0") != 0) {
        wlr_log(WLR_ERROR, "[input/udev] libinput udev context / seat0 failed");
        if (li) libinput_unref(li);
        udev_unref(udev);
        return false;
    }
    server->libinput_ctx = li;
    server->udev_ctx = udev;
    return true;
}

/* uid_map other than the identity "0 0 4294967295" → we are in a user namespace */
static bool in_user_namespace() {
    std::ifstream f("/proc/self/uid_map");
    unsigned long inside = 0, outside = 0, count = 0;
    if (!(f >> inside >> outside >> count)) return false;
    return !(inside == 0 && outside == 0 && count == 4294967295UL);
}

static bool want_path_backend() {
    const char *env = getenv("CDH_INPUT_BACKEND");
    if (env && strcmp(env, "path") == 0) return true;
    if (env && strcmp(env, "udev") == 0) return false;
    if (env && *env)
        wlr_log(WLR_ERROR, "[input] unknown CDH_INPUT_BACKEND='%s', auto-detecting", env);
    return in_user_namespace();
}

void cd_setup_input(struct cd_server *server) {
    struct wl_event_loop *loop = wl_display_get_event_loop(server->display);

    bool use_path = want_path_backend();
    wlr_log(WLR_INFO, "[input] backend: %s", use_path ? "path (inotify)" : "udev (seat0)");
    bool ok = use_path ? setup_path_backend(server, loop) : setup_udev_backend(server);

    if (ok) {
        server->libinput_event_source = wl_event_loop_add_fd(
            loop, libinput_get_fd(server->libinput_ctx), WL_EVENT_READABLE,
            libinput_event_cb, server);
        dispatch_libinput(server, server->libinput_ctx);
    } else {
        wlr_log(WLR_ERROR, "[input] no input backend — running without input");
    }

    server->dbus_input.server = server;
    if (cd_dbus_input_init(&server->dbus_input)) {
        int dbus_fd = server->dbus_input.bus_fd;
        if (dbus_fd >= 0) {
            wl_event_loop_add_fd(loop, dbus_fd, WL_EVENT_READABLE,
                [](int fd, uint32_t mask, void *data) -> int {
                    (void)fd; (void)mask;
                    cd_dbus_input_process(&static_cast<struct cd_server*>(data)->dbus_input);
                    return 0;
                }, server);
        }
    }
}
