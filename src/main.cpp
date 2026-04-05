/*
 * cloud-desktop-host — main.cpp
 * Точка входа: инициализация всех компонентов и запуск event loop.
 */
#define _POSIX_C_SOURCE 200809L

#include "server.h"

extern "C" {
#include <wlr/backend/headless.h>
#include <wlr/render/allocator.h>
#include <wlr/render/wlr_renderer.h>
#include <wlr/types/wlr_output.h>
#include <wlr/util/log.h>
}

#include <cstdlib>
#include <string>

static int hud_timer_cb(void *data) {
    auto server = (cd_server*)data;
    
    // Безусловный хартбит в 1 FPS для избежания таймаутов
    // (Sunshine падает по starvation, KWin замерзает наглухо без frame_done)
    server->needs_render = true;
    if (server->output) {
        wlr_output_schedule_frame(server->output);
    }
    
    wl_event_source_timer_update(server->hud_timer, 500);
    return 0;
}

int main(int argc, char *argv[]) {
    /* 0. Сначала инициализируем логи (пока на уровне INFO) */
    wlr_log_init(WLR_INFO, nullptr);

    struct cd_server server = {};
    server.debug        = false;
    server.hud          = false;
    server.no_auto_lock = false;

    /* Парсинг аргументов:
     *   --debug / -d       → verbose WLR_DEBUG logging
     *   --hud  / hud       → HUD overlay поверх стрима
     *   --no-auto-lock     → не отправлять авто-RCTRL при маппинге клиента
     *                        (для Steam режима: RCTRL не нужен, может мешать) */
    for (int i = 1; i < argc; i++) {
        std::string arg(argv[i]);
        if (arg == "--debug" || arg == "-d") {
            server.debug = true;
        } else if (arg == "--hud" || arg == "hud") {
            server.hud = true;
        } else if (arg == "--no-auto-lock") {
            server.no_auto_lock = true;
        }
    }

    /* Уровень логирования */
    if (server.debug) {
        wlr_log_init(WLR_DEBUG, nullptr);
        wlr_log(WLR_INFO, "Debug logging enabled");
    }

    /* Лог всех аргументов для уверенности */
    wlr_log(WLR_INFO, "[main] Starting with %d arguments:", argc);
    for (int i = 0; i < argc; i++) {
        wlr_log(WLR_INFO, "[main]   argv[%d] = '%s'", i, argv[i]);
    }

    /* 1. Display */
    server.display = wl_display_create();
    if (!server.display) return 1;

    /* 2. Backend (headless) */
    server.backend = wlr_headless_backend_create(
        wl_display_get_event_loop(server.display));
    if (!server.backend) return 1;

    /* 3. Renderer (GLES2) */
    server.renderer = wlr_renderer_autocreate(server.backend);
    if (!server.renderer) return 1;
    wlr_renderer_init_wl_display(server.renderer, server.display);

    /* 4. Allocator (GBM) */
    server.allocator = wlr_allocator_autocreate(server.backend, server.renderer);
    if (!server.allocator) return 1;

    /* 5. Протоколы (18 шт) */
    cd_register_protocols(&server);

    /* 6. XDG shell handlers (toplevel lifecycle) */
    cd_setup_xdg_handlers(&server);

    /* 7. Input handler (standalone libinput) */
    cd_setup_input(&server);

    /* 8. Headless output (1920×1080 @ 60Hz) */
    cd_setup_output(&server);
    if (!server.output) return 1;

    /* 9. Сокет */
    if (wl_display_add_socket(server.display, "wayland-cd") != 0) {
        wlr_log(WLR_ERROR, "Failed to create wayland-cd socket");
        return 1;
    }
    wlr_log(WLR_INFO, "Compositor listening on wayland-cd");

    /* 10. Запуск backend'а */
    if (!wlr_backend_start(server.backend)) {
        wlr_log(WLR_ERROR, "Failed to start backend");
        return 1;
    }

    /* 11. Event loop */
    wlr_log(WLR_INFO, "Running event loop...");

    /* HUD Timer: Принудительное обновление интерфейса раз в секунду */
    server.hud_timer = wl_event_loop_add_timer(wl_display_get_event_loop(server.display), hud_timer_cb, &server);
    wl_event_source_timer_update(server.hud_timer, 500);

    wl_display_run(server.display);

    /* Cleanup */
    cd_dbus_input_shutdown(&server.dbus_input);
    wl_display_destroy(server.display);
    return 0;
}
