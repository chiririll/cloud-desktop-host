/*
 * cloud-desktop-host — server.h
 * Центральная структура состояния композитора.
 */
#ifndef CD_SERVER_H
#define CD_SERVER_H

/* wlroots — C API, нужен extern "C" для C++.
 * wlroots >= 0.19 использует в прототипах C99 `float m[static 9]`, что не парсится
 * в C++: на время include убираем ключевое слово `static` (см. wlr_cxx_begin.h). */
#include "wlr_cxx_begin.h"
extern "C" {
#include <wayland-server-core.h>
#include <wlr/backend.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
}
#include "wlr_cxx_end.h"

#include "dbus_input.h"

#define CD_DEFAULT_WIDTH   1920
#define CD_DEFAULT_HEIGHT  1080
#define CD_DEFAULT_REFRESH 60000   /* mHz — стартовое значение, меняется через SetOutputMode */

#define CD_HEARTBEAT_ACTIVE_MS   500   /* heartbeat во время стрима */
#define CD_HEARTBEAT_IDLE_MS    1000   /* heartbeat в idle: единственный источник frame_done */
#define CD_IDLE_TIMEOUT_DEFAULT   10   /* сек без screencopy → idle (0 = авто-idle выключен) */

struct cd_server {
    /* ── Core ── */
    struct wl_display          *display;
    bool                        debug;        /* --debug / -d     : verbose WLR_DEBUG logging */
    bool                        hud;          /* --hud            : HUD overlay */
    bool                        no_auto_lock; /* --no-auto-lock   : не отправлять авто-RCTRL клиенту */
    struct wlr_backend         *backend;
    struct wlr_renderer        *renderer;
    struct wlr_allocator       *allocator;

    /* ── Output ── */
    struct wlr_output          *output;
    struct wlr_output_layout   *output_layout;
    /* HUD (R2 timing) */
    struct wl_event_source     *hud_timer;

    /* Renders state (R1 damage-driven) */
    bool                        needs_render;
    struct wl_listener          output_frame;
    struct wl_listener          present_refresh_fixup;
    float                       phase;
    unsigned long               frame_count;
    struct timespec              last_frame_time;
    struct timespec              last_desktop_commit_time;
    struct timespec              last_mouse_activity_time;
    int                         cur_width;
    int                         cur_height;
    int                         cur_refresh;    /* mHz */

    /* ── Idle mode ──
     * Нет захвата (Sunshine не стримит) → рендер и frame_done только по
     * heartbeat (1 Гц). KWin/Gamescope и их клиенты троттлятся следом.
     * Вход: idle_timeout_sec без screencopy или D-Bus SetIdle(true).
     * Выход: запрос screencopy, SetOutputMode или SetIdle(false). */
    struct wl_listener          client_created;   /* следим за zwlr_screencopy_frame_v1 */
    bool                        idle;
    int                         idle_timeout_sec;
    struct timespec             last_capture_time;

    /* ── XDG Shell ── */
    struct wlr_xdg_shell      *xdg_shell;
    struct wl_global           *xdg_shell_global;
    struct wl_listener          new_xdg_toplevel;

    /* ── Desktop surface (от KWin) ── */
    struct wlr_xdg_toplevel   *desktop_toplevel;
    struct wlr_surface         *desktop_surface;
    struct wl_listener          desktop_map;
    struct wl_listener          desktop_unmap;
    struct wl_listener          desktop_destroy;
    struct wl_listener          desktop_commit;

    /* ── Seat ── */
    struct wlr_seat            *seat;
    struct wlr_relative_pointer_manager_v1 *relative_pointer_mgr;
    struct wl_listener          relative_pointer_new;
    struct wl_listener          relative_pointer_destroy;
    struct wlr_pointer_constraints_v1 *pointer_constraints;
    struct wl_listener          new_pointer_constraint;
    struct wl_listener          active_constraint_destroy;
    bool                        has_active_constraint;  /* locked pointer активен */
    bool                        pointer_lock_sent;      /* RIGHT_CTRL отправлен */
    bool                        abs_synced;             /* absolute-mouse origin synced with KWin's locked cursor */
    struct wl_event_source     *pointer_lock_timer;

    /* ── Pointer position (для seat notify_motion) ── */
    double                      cursor_x;
    double                      cursor_y;

    /* ── Input (1.5) ── */
    struct wl_listener          new_input;
    struct wlr_pointer         *active_pointer;
    struct wlr_keyboard        *active_keyboard;
    struct wl_listener          pointer_motion;
    struct wl_listener          pointer_motion_abs;
    struct wl_listener          pointer_button;
    struct wl_listener          pointer_axis;
    struct wl_listener          pointer_frame;
    struct wl_listener          keyboard_key;
    struct wl_listener          keyboard_modifiers;

    /* ── libinput (standalone) ── */
    struct libinput            *libinput_ctx;
    struct udev                *udev_ctx;
    struct wl_event_source     *libinput_event_source;

    /* ── Diagnostic HUD data ── */
    double                      hud_fps;
    double                      hud_mouse_dx;
    double                      hud_mouse_dy;
    bool                        hud_pointer_locked;
    uint32_t                    hud_kwin_commits;        /* общий счётчик коммитов для Rate */
    uint32_t                    hud_watchdog_commits;    /* Raw counter для Watchdog WL Surface Frame */
    double                      hud_kwin_commit_rate;    /* commits/sec */
    uint32_t                    hud_constraint_count;    /* запросы pointer_constraint */

    /* ── D-Bus Input (org.gamescope.Input) ── */
    struct cd_dbus_input        dbus_input;
    struct wl_event_source     *dbus_event_source;
};

/* ── Публичные API модулей ── */

extern "C" {

/* protocols.cpp */
void cd_register_protocols(struct cd_server *server);

/* output.cpp */
void cd_setup_output(struct cd_server *server);

/* idle.cpp */
void cd_idle_setup(struct cd_server *server);   /* до wl_display_add_socket */
void cd_idle_tick(struct cd_server *server);    /* из heartbeat: авто-вход по таймауту */
void cd_idle_enter(struct cd_server *server, const char *reason);
void cd_idle_exit(struct cd_server *server, const char *reason);

/* xdg.cpp */
void cd_setup_xdg_handlers(struct cd_server *server);

/* input.cpp */
void cd_setup_input(struct cd_server *server);

}

#endif /* CD_SERVER_H */
