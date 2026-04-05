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
#include <linux/input-event-codes.h>

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

    if (!server->has_active_constraint) {
        struct wlr_surface *focused = server->seat->pointer_state.focused_surface;
        if (!focused && server->desktop_surface) {
            wlr_seat_pointer_notify_enter(server->seat, server->desktop_surface, x, y);
        }
        wlr_seat_pointer_notify_motion(server->seat, time, x, y);
    }

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
        case LIBINPUT_EVENT_DEVICE_REMOVED:
            cd_dbus_input_device_removed(&server->dbus_input, libinput_event_get_device(event));
            break;
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

void cd_setup_input(struct cd_server *server) {
    struct udev *udev = udev_new();
    struct libinput *li = libinput_udev_create_context(&li_iface, server, udev);
    libinput_udev_assign_seat(li, "seat0");
    server->libinput_ctx = li;
    server->udev_ctx = udev;

    struct wl_event_loop *loop = wl_display_get_event_loop(server->display);
    server->libinput_event_source = wl_event_loop_add_fd(
        loop, libinput_get_fd(li), WL_EVENT_READABLE, libinput_event_cb, server);

    dispatch_libinput(server, li);

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
