/*
 * cloud-desktop-host — xdg.cpp
 * XDG Shell lifecycle: toplevel → map → commit → destroy.
 */
#define _POSIX_C_SOURCE 200809L

#include "server.h"

extern "C" {
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_output.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/util/log.h>
#include <wayland-server-protocol.h>
}

#include <ctime>
#include <linux/input-event-codes.h>

/*
 * auto_pointer_lock_timer_cb — срабатывает через 200ms после map desktop surface.
 * Отправляет KWin виртуальный RCTRL → KWin вызывает togglePointerLock()
 * → создаёт zwp_locked_pointer_v1 → CDH немедленно активирует
 * → m_hasPointerLock = true → KWin рисует курсор в main framebuffer.
 * Это делает курсор видимым в стриме с первого кадра без ручного RCTRL.
 */
static int auto_pointer_lock_timer_cb(void *data) {
    struct cd_server *server = (struct cd_server *)data;

    if (server->pointer_lock_sent || !server->desktop_surface) {
        return 0;
    }

    server->pointer_lock_sent = true;

    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    uint32_t t = (uint32_t)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);

    wlr_seat_keyboard_notify_key(server->seat, t,
        KEY_RIGHTCTRL, WL_KEYBOARD_KEY_STATE_PRESSED);
    wlr_seat_keyboard_notify_key(server->seat, t + 1,
        KEY_RIGHTCTRL, WL_KEYBOARD_KEY_STATE_RELEASED);

    wlr_log(WLR_INFO, "[auto-lock] Sent RCTRL → KWin for automatic pointer lock");
    return 0;
}

/*
 * handle_desktop_commit — commit от KWin.
 * Вместо frame_done (уже отправляется при рендере) —
 * schedule_frame для немедленной перерисовки.
 */
static void handle_desktop_commit(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server =
        wl_container_of(listener, server, desktop_commit);

    if (!server->desktop_surface || !server->output) return;

    server->hud_kwin_commits++;
    server->hud_watchdog_commits++;

    /* KWin прислал новый буфер — перерисовываем немедленно.
     * В idle только помечаем: кадр (и frame_done) выдаст heartbeat,
     * что и троттлит KWin/Gamescope вместе с их клиентами. */
    server->needs_render = true;
    if (!server->idle)
        wlr_output_schedule_frame(server->output);
}

/*
 * handle_desktop_map — XDG surface замаппилась (KWin отправил буфер).
 */
static void handle_desktop_map(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server =
        wl_container_of(listener, server, desktop_map);

    server->desktop_surface = server->desktop_toplevel->base->surface;

    wlr_log(WLR_INFO, "Desktop surface mapped (%dx%d)",
            server->desktop_surface->current.width,
            server->desktop_surface->current.height);

    /* Переключаем слушатель коммита с handshake-версии на рендер-версию */
    wl_list_remove(&server->desktop_commit.link);
    server->desktop_commit.notify = handle_desktop_commit;
    wl_signal_add(&server->desktop_surface->events.commit,
                  &server->desktop_commit);

    /*
     * Передать фокус KWin — без этого KWin не отправит set_cursor!
     */
    wlr_seat_pointer_notify_enter(server->seat,
        server->desktop_surface,
        server->cursor_x, server->cursor_y);

    struct wl_array empty_keys;
    wl_array_init(&empty_keys);
    wlr_seat_keyboard_notify_enter(server->seat,
        server->desktop_surface, 
        static_cast<uint32_t*>(empty_keys.data), empty_keys.size, nullptr);
    wl_array_release(&empty_keys);

    wlr_log(WLR_INFO, "Focus set: pointer + keyboard → desktop surface");

    /* Автоматический pointer lock через 200ms.
     * Даём KWin время обработать keyboard_enter до получения RCTRL.
     * В режиме --no-auto-lock (Steam) пропускаем — RCTRL не нужен.
     * Для Gamescope тоже пропускаем — Gamescope скрывает курсор при
     * m_bPointerLocked=true (WaylandBackend.cpp:2459). */
    bool skip_auto_lock = server->no_auto_lock;
    if (!skip_auto_lock) {
        /* Проверяем comm клиента — gamescope не нуждается в pointer lock */
        struct wl_client *client = wl_resource_get_client(
            server->desktop_surface->resource);
        pid_t pid = 0;
        wl_client_get_credentials(client, &pid, nullptr, nullptr);
        if (pid > 0) {
            char comm_path[64], comm[64] = {0};
            snprintf(comm_path, sizeof(comm_path), "/proc/%d/comm", pid);
            FILE *f = fopen(comm_path, "r");
            if (f) {
                if (fgets(comm, sizeof(comm), f)) {
                    comm[strcspn(comm, "\n")] = '\0';
                    if (strcmp(comm, "gamescope") == 0) {
                        skip_auto_lock = true;
                        wlr_log(WLR_INFO, "[auto-lock] Skipped for gamescope client");
                    }
                }
                fclose(f);
            }
        }
    }
    if (!skip_auto_lock && !server->pointer_lock_sent && server->pointer_lock_timer) {
        wl_event_source_timer_update(server->pointer_lock_timer, 200);
        wlr_log(WLR_INFO, "[auto-lock] Timer armed (200ms)");
    } else if (server->no_auto_lock) {
        wlr_log(WLR_INFO, "[auto-lock] Skipped (--no-auto-lock mode)");
    }
}

/*
 * handle_desktop_unmap — surface скрывается.
 */
static void handle_desktop_unmap(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server =
        wl_container_of(listener, server, desktop_unmap);

    wlr_log(WLR_INFO, "Desktop surface unmapped");
    wl_list_remove(&server->desktop_commit.link);
    server->desktop_surface = nullptr;
}

/*
 * handle_desktop_destroy — XDG toplevel уничтожен.
 */
static void handle_desktop_destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server =
        wl_container_of(listener, server, desktop_destroy);

    wlr_log(WLR_INFO, "Desktop toplevel destroyed");

    /* Сбрасываем флаг — при повторном подключении KWin авто-лок сработает снова */
    server->pointer_lock_sent = false;

    wl_list_remove(&server->desktop_map.link);
    wl_list_remove(&server->desktop_unmap.link);
    wl_list_remove(&server->desktop_destroy.link);

    if (server->desktop_surface) {
        wl_list_remove(&server->desktop_commit.link);
        server->desktop_surface = nullptr;
    }
    server->desktop_toplevel = nullptr;
}

static void handle_xdg_surface_commit(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server = wl_container_of(listener, server, desktop_commit);
    server->hud_watchdog_commits++;
    clock_gettime(CLOCK_MONOTONIC, &server->last_desktop_commit_time);
    struct wlr_xdg_surface *xdg_surface = server->desktop_toplevel->base;

    if (xdg_surface->initial_commit) {
        /* Используем ТЕКУЩИЙ режим вывода, а не CD_DEFAULT.
         * prep-cmd мог вызвать SetOutputMode ДО подключения KWin
         * (например, Moonlight подключился в 720p пока KWin стартовал).
         * В этом случае server->cur_width/height уже обновлены,
         * и KWin должен получить правильный размер с первого configure. */
        wlr_xdg_toplevel_set_size(server->desktop_toplevel,
            server->cur_width, server->cur_height);
        wlr_xdg_toplevel_set_fullscreen(server->desktop_toplevel, server->output);
        wlr_xdg_toplevel_set_activated(server->desktop_toplevel, true);
        wlr_xdg_surface_schedule_configure(xdg_surface);
        wlr_log(WLR_INFO, "XDG surface initial commit: sent configure (%dx%d, fullscreen)",
                server->cur_width, server->cur_height);
        return;
    }

    /* Fallback для клиентов (Gamescope/libdecor) которые не trigger'ят map event.
     * Если surface имеет буфер но desktop_surface ещё не установлен —
     * устанавливаем вручную и начинаем рендеринг. */
    if (!server->desktop_surface && server->output &&
        wlr_surface_has_buffer(xdg_surface->surface)) {
        server->desktop_surface = xdg_surface->surface;
        wlr_log(WLR_INFO, "XDG surface has buffer (manual map fallback, %dx%d)",
                xdg_surface->surface->current.width,
                xdg_surface->surface->current.height);

        /* Переключаем на рендер-версию commit handler */
        wl_list_remove(&server->desktop_commit.link);
        server->desktop_commit.notify = handle_desktop_commit;
        wl_signal_add(&server->desktop_surface->events.commit,
                      &server->desktop_commit);

        /* Focus */
        wlr_seat_pointer_notify_enter(server->seat,
            server->desktop_surface,
            server->cursor_x, server->cursor_y);
        struct wl_array empty_keys;
        wl_array_init(&empty_keys);
        wlr_seat_keyboard_notify_enter(server->seat,
            server->desktop_surface,
            static_cast<uint32_t*>(empty_keys.data), empty_keys.size, nullptr);
        wl_array_release(&empty_keys);

        wlr_log(WLR_INFO, "Focus set: pointer + keyboard → desktop surface (fallback)");
    }

    /* Планируем отрисовку если desktop_surface уже есть */
    if (server->desktop_surface && server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
}

/*
 * handle_new_xdg_toplevel — новый XDG toplevel от клиента.
 * KWin-режим: первый toplevel — KWin, все остальные игнорируются.
 * Steam-режим (--no-auto-lock): Xwayland запускается fullscreen —
 * его единственный toplevel становится desktop_toplevel.
 * Steam рендерит X11 контент в Xwayland, CDH стримит Xwayland окно.
 */
static void handle_new_xdg_toplevel(struct wl_listener *listener, void *data) {
    struct cd_server *server =
        wl_container_of(listener, server, new_xdg_toplevel);
    auto *toplevel = static_cast<struct wlr_xdg_toplevel*>(data);

    if (server->desktop_toplevel == nullptr) {
        wlr_log(WLR_INFO, "=== Desktop toplevel created ===");

        server->desktop_toplevel = toplevel;

        server->desktop_map.notify = handle_desktop_map;
        wl_signal_add(&toplevel->base->surface->events.map,
                      &server->desktop_map);

        server->desktop_unmap.notify = handle_desktop_unmap;
        wl_signal_add(&toplevel->base->surface->events.unmap,
                      &server->desktop_unmap);

        server->desktop_destroy.notify = handle_desktop_destroy;
        wl_signal_add(&toplevel->events.destroy,
                      &server->desktop_destroy);

        /* Добавляем временный слушатель коммита для хендшейка */
        server->desktop_commit.notify = handle_xdg_surface_commit;
        wl_signal_add(&toplevel->base->surface->events.commit,
                      &server->desktop_commit);
    } else {
        wlr_log(WLR_INFO, "Additional xdg_toplevel (non-desktop)");
        wlr_xdg_toplevel_set_size(toplevel, 0, 0);
    }
}

void cd_setup_xdg_handlers(struct cd_server *server) {
    server->new_xdg_toplevel.notify = handle_new_xdg_toplevel;
    wl_signal_add(&server->xdg_shell->events.new_toplevel,
                  &server->new_xdg_toplevel);

    /* Таймер для автоматического pointer lock при подключении KWin.
     * Арм производится в handle_desktop_map, не здесь. */
    server->pointer_lock_timer = wl_event_loop_add_timer(
        wl_display_get_event_loop(server->display),
        auto_pointer_lock_timer_cb, server);
}
