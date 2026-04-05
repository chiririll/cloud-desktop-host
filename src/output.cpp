/*
 * cloud-desktop-host — output.cpp
 * Восстановленная версия с постоянным таймером (heartbeat).
 */
#define _POSIX_C_SOURCE 200809L

#include "server.h"
#include "debug_ui.h"

extern "C" {
#include <wlr/backend/headless.h>
#include <wlr/render/pass.h>
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/util/log.h>
}

#include <cmath>
#include <ctime>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

/* ── Рендер одной surface ── */
struct render_data {
    struct wlr_render_pass *pass;
};

static void render_surface_iterator(struct wlr_surface *surface,
                                    int sx, int sy, void *data) {
    auto *rdata = static_cast<struct render_data*>(data);

    if (!wlr_surface_has_buffer(surface)) return;

    struct wlr_texture *texture = wlr_surface_get_texture(surface);
    if (!texture) return;

    struct wlr_render_texture_options opts = {};
    opts.texture = texture;
    opts.dst_box.x = sx;
    opts.dst_box.y = sy;
    opts.dst_box.width  = surface->current.width;
    opts.dst_box.height = surface->current.height;
    wlr_render_pass_add_texture(rdata->pass, &opts);
}

/*
 * Перехватчик present event headless backend.
 * Headless backend отправляет present event с refresh=0 (wlr_output_send_present
 * не заполняет поле из output->refresh).
 * wlr_presentation читает это 0 и шлёт KWin refresh=0 через wp_presentation_feedback.
 * KWin при refresh=0 остаётся на текущем m_refreshRate (60000 mHz по умолчанию).
 * Этот handler инжектирует корректный refresh (период кадра в наносекундах)
 * из server->cur_refresh (в mHz), который обновляется через D-Bus SetOutputMode.
 *
 * ВАЖНО: регистрируется через wl_list_insert в HEAD списка listener_list,
 * чтобы сработать ДО feedback-listener'а wlr_presentation (тот в ХВОСТЕ).
 */
static void handle_present_refresh_fixup(
    struct wl_listener *listener, void *data)
{
    struct cd_server *server =
        wl_container_of(listener, server, present_refresh_fixup);
    auto *event = static_cast<struct wlr_output_event_present*>(data);

    if (server->cur_refresh > 0) {
        /* cur_refresh в mHz, refresh в наносекундах (период кадра)
         * 120000 mHz → 1'000'000'000'000 / 120000 = 8'333'333 ns */
        event->refresh = (int)(1000000000000LL / server->cur_refresh);
    }
}

/* ── Frame handler (Damage-driven) ── */
static void handle_output_frame(struct wl_listener *listener, void *data) {
    (void)data;
    struct cd_server *server =
        wl_container_of(listener, server, output_frame);
    struct wlr_output *output = server->output;

    if (!server->needs_render) {
        return; // Пропускаем commit_state. Стрим падает до 0 FPS.
    }
    server->needs_render = false;

    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);

    /* ── Watchdog Detector (R5 / KWin Present Rejection) [DISABLED] ──
    if (server->has_active_constraint) {
        ...
    }
    */

    struct wlr_output_state state;
    wlr_output_state_init(&state);

    int buffer_age;
    struct wlr_render_pass *pass =
        wlr_output_begin_render_pass(output, &state, &buffer_age, nullptr);
    if (!pass) {
        wlr_output_state_finish(&state);
        return;
    }

    /* Чёрный фон */
    struct wlr_render_rect_options bg = {};
    bg.box.width  = output->width;
    bg.box.height = output->height;
    bg.color.a = 1.0f;
    wlr_render_pass_add_rect(pass, &bg);

    if (server->desktop_surface) {
        /* Desktop */
        struct render_data rdata = {};
        rdata.pass = pass;
        wlr_surface_for_each_surface(server->desktop_surface,
            render_surface_iterator, &rdata);

        /* HUD */
        cd_render_debug_overlay(server, pass);


        /* Present refresh fixup: вставляем в HEAD ПЕРЕД регистрацией surface.
         * wl_signal_add добавляет в ХВОСТ — listener срабатывает ПОСЛЕ
         * wlr_presentation, когда event->refresh уже прочитан (refresh=0).
         * wl_list_insert(&signal.listener_list, ...) вставляет сразу за
         * sentinel-головой → HEAD списка → срабатывает ПЕРВЫМ. */
        wl_list_remove(&server->present_refresh_fixup.link);
        wl_list_init(&server->present_refresh_fixup.link);
        server->present_refresh_fixup.notify = handle_present_refresh_fixup;
        wl_list_insert(&server->output->events.present.listener_list,
                       &server->present_refresh_fixup.link);

        /* Presentation feedback: привязка surface → output.
         * Feedback listener добавляется в ХВОСТ, ПОСЛЕ нашего фикса. */
        wlr_presentation_surface_textured_on_output(
            server->desktop_surface, server->output);
    } else {
        /* Тестовая анимация */
        server->phase += 0.005f;
        if (server->phase > 1.0f) server->phase -= 1.0f;
        float r = (sinf(server->phase * 2.0f * (float)M_PI)          + 1.0f) / 2.0f;
        float g = (sinf(server->phase * 2.0f * (float)M_PI + 2.094f) + 1.0f) / 2.0f;
        float b = (sinf(server->phase * 2.0f * (float)M_PI + 4.189f) + 1.0f) / 2.0f;
        struct wlr_render_rect_options test = {};
        test.box.width  = output->width;
        test.box.height = output->height;
        test.color = { .r = r, .g = g, .b = b, .a = 1.0f };
        wlr_render_pass_add_rect(pass, &test);
    }

    wlr_render_pass_submit(pass);
    if (!wlr_output_commit_state(output, &state)) {
        wlr_log(WLR_ERROR, "output commit failed");
    }
    wlr_output_state_finish(&state);

    /* Обновляем now ПОСЛЕ commit — для точного frame_done timestamp */
    clock_gettime(CLOCK_MONOTONIC, &now);
    server->frame_count++;
    server->last_frame_time = now;

    /* frame_done отправляется ПОСЛЕ commit, чтобы KWin не коммитил
     * следующий кадр раньше, чем мы завершили текущий. Это критично
     * для игр: без этого возникает гонка и frame pipeline ломается. */
    if (server->desktop_surface) {
        wlr_surface_send_frame_done(server->desktop_surface, &now);
    }

    /* Статистика FPS — обновление HUD раз в 500 ms */
    static const double hud_update_interval_sec = 0.5;
    static struct timespec last_fps_time;
    static uint64_t last_report_frame = 0;
    static uint32_t last_kwin_commits = 0;
    double elapsed = (now.tv_sec - last_fps_time.tv_sec) +
                     (now.tv_nsec - last_fps_time.tv_nsec) / 1e9;
    if (elapsed >= hud_update_interval_sec) {
        server->hud_fps = (server->frame_count - last_report_frame) / elapsed;
        server->hud_kwin_commit_rate = (server->hud_kwin_commits - last_kwin_commits) / elapsed;

        last_fps_time = now;
        last_report_frame = server->frame_count;
        last_kwin_commits = server->hud_kwin_commits;
    }

    server->hud_mouse_dx = 0;
    server->hud_mouse_dy = 0;
}

void cd_setup_output(struct cd_server *server) {
    server->output = wlr_headless_add_output(
        server->backend, CD_DEFAULT_WIDTH, CD_DEFAULT_HEIGHT);
    if (!server->output) return;

    wlr_output_init_render(server->output, server->allocator, server->renderer);

    struct wlr_output_state out_state;
    wlr_output_state_init(&out_state);
    wlr_output_state_set_enabled(&out_state, true);
    /* Возвращаем фиксированную частоту для стабильности */
    wlr_output_state_set_custom_mode(&out_state,
        CD_DEFAULT_WIDTH, CD_DEFAULT_HEIGHT, CD_DEFAULT_REFRESH);
    
    if (!wlr_output_commit_state(server->output, &out_state)) {
        wlr_log(WLR_ERROR, "Failed to commit output state");
        wlr_output_state_finish(&out_state);
        return;
    }
    wlr_output_state_finish(&out_state);

    wlr_output_layout_add_auto(server->output_layout, server->output);
    server->output_frame.notify = handle_output_frame;
    wl_signal_add(&server->output->events.frame, &server->output_frame);

    /* Инициализируем listener link, чтобы wl_list_remove не падал */
    wl_list_init(&server->present_refresh_fixup.link);

    server->cur_width = CD_DEFAULT_WIDTH;
    server->cur_height = CD_DEFAULT_HEIGHT;
    server->cur_refresh = CD_DEFAULT_REFRESH;
}
