/*
 * cloud-desktop-host — protocols.cpp
 * Регистрация всех Wayland протоколов, необходимых для KWin.
 */
#define _POSIX_C_SOURCE 200809L

#include "server.h"

extern "C" {
#include <wlr/types/wlr_compositor.h>
#include <wlr/types/wlr_subcompositor.h>
#include <wlr/types/wlr_data_device.h>
#include <wlr/types/wlr_output_layout.h>
#include <wlr/types/wlr_xdg_output_v1.h>
#include <wlr/types/wlr_xdg_shell.h>
#include <wlr/types/wlr_linux_dmabuf_v1.h>
#include <wlr/types/wlr_screencopy_v1.h>
#include <wlr/types/wlr_seat.h>
#include <wlr/types/wlr_viewporter.h>
#include <wlr/types/wlr_single_pixel_buffer_v1.h>
#include <wlr/types/wlr_presentation_time.h>
#include <wlr/types/wlr_xdg_decoration_v1.h>
#include <wlr/types/wlr_fractional_scale_v1.h>
#include <wlr/types/wlr_pointer_constraints_v1.h>
#include <wlr/types/wlr_xdg_activation_v1.h>
#include <wlr/types/wlr_content_type_v1.h>
#include <wlr/types/wlr_relative_pointer_v1.h>
#include <wlr/util/log.h>
}

#include <cstring>
#include <cstdio>

/* ── Утилита: получить comm (имя процесса) клиента по PID ── */
static bool get_client_comm(struct wl_client *client, char *out, size_t out_size) {
    pid_t pid;
    wl_client_get_credentials(client, &pid, nullptr, nullptr);

    char path[64];
    snprintf(path, sizeof(path), "/proc/%d/comm", pid);

    FILE *f = fopen(path, "r");
    if (!f) return false;

    out[0] = '\0';
    if (fgets(out, out_size, f)) {
        char *nl = strchr(out, '\n');
        if (nl) *nl = '\0';
    }
    fclose(f);
    return out[0] != '\0';
}

/* ── PID-based global filter: xdg_wm_base только для KWin / Xwayland / gamescope ── */
static bool is_kwin_client(struct wl_client *client) {
    char comm[64];
    return get_client_comm(client, comm, sizeof(comm)) &&
           strcmp(comm, "kwin_wayland") == 0;
}

static bool is_xwayland_client(struct wl_client *client) {
    char comm[64];
    return get_client_comm(client, comm, sizeof(comm)) &&
           strcmp(comm, "Xwayland") == 0;
}

static bool is_gamescope_client(struct wl_client *client) {
    char comm[64];
    return get_client_comm(client, comm, sizeof(comm)) &&
           strcmp(comm, "gamescope") == 0;
}

static bool global_filter_cb([[maybe_unused]] const struct wl_client *client,
                             [[maybe_unused]] const struct wl_global *global,
                             void *data) {
    struct cd_server *server = static_cast<struct cd_server*>(data);

    if (global == server->xdg_shell_global) {
        auto *nc_client = const_cast<struct wl_client*>(client);
        return is_gamescope_client(nc_client) ||
               (server->no_auto_lock ? is_xwayland_client(nc_client) : is_kwin_client(nc_client));
    }
    return true;
}

void cd_register_protocols(struct cd_server *server) {
    struct wl_display *display = server->display;

    /* 1. wl_compositor (v6) */
    wlr_compositor_create(display, 6, server->renderer);

    /* 2. wl_subcompositor (явно — KWin требует!) */
    wlr_subcompositor_create(display);

    /* 3. wl_shm (авто через wlr_renderer_init_wl_display) */

    /* 4. xdg_wm_base (XDG shell) */
    server->xdg_shell = wlr_xdg_shell_create(display, 6);
    /* Сохраняем global для фильтра */
    server->xdg_shell_global = server->xdg_shell->global;

    /* 5. PID-фильтр: xdg_wm_base виден только kwin_wayland */
    wl_display_set_global_filter(display, global_filter_cb, server);
    wlr_log(WLR_INFO, "xdg_wm_base: PID filter active (kwin_wayland / Xwayland)");

    /* 6. Viewporter */
    wlr_viewporter_create(display);

    /* 7. single_pixel_buffer_v1 */
    wlr_single_pixel_buffer_manager_v1_create(display);

    /* 8. zwp_linux_dmabuf_v1 */
    wlr_linux_dmabuf_v1_create_with_renderer(display, 5, server->renderer);

    /* 9. wl_seat */
    server->seat = wlr_seat_create(display, "seat0");
    wlr_seat_set_capabilities(server->seat,
        WL_SEAT_CAPABILITY_POINTER | WL_SEAT_CAPABILITY_KEYBOARD);

    /* 10. Output layout */
    server->output_layout = wlr_output_layout_create(display);

    /* 11. xdg_output_manager */
    wlr_xdg_output_manager_v1_create(display, server->output_layout);

    /* 12. wlr_screencopy_manager_v1 */
    wlr_screencopy_manager_v1_create(display);

    /* 13. wp_presentation */
    wlr_presentation_create(display, server->backend, 2);

    /* 14. xdg_decoration_manager */
    wlr_xdg_decoration_manager_v1_create(display);

    /* 15. fractional_scale_manager */
    wlr_fractional_scale_manager_v1_create(display, 1);

    /* 16. pointer_constraints */
    server->pointer_constraints = wlr_pointer_constraints_v1_create(display);
    wl_list_init(&server->active_constraint_destroy.link);

    server->new_pointer_constraint.notify = [](struct wl_listener *listener, void *data) {
        struct cd_server *server = wl_container_of(listener, server, new_pointer_constraint);
        auto *constraint = static_cast<struct wlr_pointer_constraint_v1*>(data);
        
        wlr_log(WLR_INFO, "New Pointer constraint request (LOCKED mode initiated)");
        server->hud_constraint_count++;
        server->has_active_constraint = true;
        server->abs_synced = false;
        server->hud_pointer_locked = true;

        // Удаляем старый листенер, если он был (для страховки)
        wl_list_remove(&server->active_constraint_destroy.link);

        server->active_constraint_destroy.notify = [](struct wl_listener *listener, void *data) {
            struct cd_server *server = wl_container_of(listener, server, active_constraint_destroy);
            wlr_log(WLR_INFO, "Pointer constraint DESTROYED (FREE mode restored)");
            server->has_active_constraint = false;
            server->hud_pointer_locked = false;
            wl_list_remove(&server->active_constraint_destroy.link);
            wl_list_init(&server->active_constraint_destroy.link);
            if (server->output) {
                server->needs_render = true;
                wlr_output_schedule_frame(server->output);
            }
        };
        wl_signal_add(&constraint->events.destroy, &server->active_constraint_destroy);

        // Подтверждаем KWin, что мы активировали лок.
        wlr_pointer_constraint_v1_send_activated(constraint);
    };
    wl_signal_add(&server->pointer_constraints->events.new_constraint,
                  &server->new_pointer_constraint);

    /* 17. xdg_activation */
    wlr_xdg_activation_v1_create(display);

    /* 18. data_device_manager (clipboard) */
    wlr_data_device_manager_create(display);

    /* 19. content_type_manager */
    wlr_content_type_manager_v1_create(display, 1);

    /* 20. relative_pointer_manager (для игр — relative mouse motion) */
    server->relative_pointer_mgr =
        wlr_relative_pointer_manager_v1_create(display);

    wlr_log(WLR_INFO, "All protocols registered (20 interfaces)");
}
