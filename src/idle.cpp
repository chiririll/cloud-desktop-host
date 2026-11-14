/*
 * cloud-desktop-host — idle.cpp
 * Idle mode: троттлинг вложенного композитора, когда никто не стримит.
 *
 * Когда никто не захватывает экран, CDH перестаёт сразу отвечать на
 * коммиты KWin/Gamescope: рендер и frame_done идут только по heartbeat
 * (CD_HEARTBEAT_IDLE_MS). Вложенный композитор ждёт frame_done перед
 * следующим кадром, его клиенты ждут его — вся цепочка падает до ~1 FPS.
 * Режим вывода (cur_refresh) не меняется: KWin не перестраивает раскладку.
 *
 * Вход:  idle_timeout_sec без screencopy (cd_idle_tick) или D-Bus SetIdle(true).
 * Выход: новый screencopy-кадр, SetOutputMode или D-Bus SetIdle(false).
 */
#define _POSIX_C_SOURCE 200809L

#include "server.h"

extern "C" {
#include <wlr/util/log.h>
}

#include <cstring>
#include <ctime>

void cd_idle_enter(struct cd_server *server, const char *reason) {
    if (server->idle) return;
    server->idle = true;
    wlr_log(WLR_INFO, "[idle] ON (%s): frame_done every %d ms",
            reason, CD_HEARTBEAT_IDLE_MS);
    /* Таймер перевзведёт себя с idle-интервалом при следующем срабатывании */
}

void cd_idle_exit(struct cd_server *server, const char *reason) {
    /* Даём новый льготный период: prep-скрипт уже отработал,
     * а Sunshine начнёт захват чуть позже. */
    clock_gettime(CLOCK_MONOTONIC, &server->last_capture_time);
    if (!server->idle) return;
    server->idle = false;
    wlr_log(WLR_INFO, "[idle] OFF (%s)", reason);
    if (server->output) {
        server->needs_render = true;
        wlr_output_schedule_frame(server->output);
    }
    if (server->hud_timer)
        wl_event_source_timer_update(server->hud_timer, CD_HEARTBEAT_ACTIVE_MS);
}

/*
 * Детектор захвата: каждый запрос кадра Sunshine создаёт новый объект
 * zwlr_screencopy_frame_v1. Ловим создание ресурса у каждого клиента —
 * не зависим от внутренностей wlroots и от «брошенных» кадров.
 */
struct cd_client_watch {
    struct cd_server   *server;
    struct wl_listener  resource_created;
    struct wl_listener  client_destroy;
};

static void handle_resource_created(struct wl_listener *listener, void *data) {
    struct cd_client_watch *watch =
        wl_container_of(listener, watch, resource_created);
    auto *resource = static_cast<struct wl_resource*>(data);
    if (strcmp(wl_resource_get_class(resource), "zwlr_screencopy_frame_v1") != 0)
        return;

    struct cd_server *server = watch->server;
    clock_gettime(CLOCK_MONOTONIC, &server->last_capture_time);
    if (server->idle)
        cd_idle_exit(server, "screencopy");
}

static void handle_watched_client_destroy(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_client_watch *watch =
        wl_container_of(listener, watch, client_destroy);
    wl_list_remove(&watch->resource_created.link);
    wl_list_remove(&watch->client_destroy.link);
    delete watch;
}

static void handle_client_created(struct wl_listener *listener, void *data) {
    struct cd_server *server =
        wl_container_of(listener, server, client_created);
    auto *client = static_cast<struct wl_client*>(data);

    auto *watch = new cd_client_watch{};
    watch->server = server;
    watch->resource_created.notify = handle_resource_created;
    wl_client_add_resource_created_listener(client, &watch->resource_created);
    watch->client_destroy.notify = handle_watched_client_destroy;
    wl_client_add_destroy_listener(client, &watch->client_destroy);
}

void cd_idle_setup(struct cd_server *server) {
    /* Льготный период на старте: idle включится, если за idle_timeout_sec
     * никто не начнёт захват */
    clock_gettime(CLOCK_MONOTONIC, &server->last_capture_time);
    server->client_created.notify = handle_client_created;
    wl_display_add_client_created_listener(server->display,
                                           &server->client_created);
}

void cd_idle_tick(struct cd_server *server) {
    if (server->idle || server->idle_timeout_sec <= 0) return;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double since = (now.tv_sec - server->last_capture_time.tv_sec) +
                   (now.tv_nsec - server->last_capture_time.tv_nsec) / 1e9;
    if (since >= server->idle_timeout_sec)
        cd_idle_enter(server, "no screencopy");
}
