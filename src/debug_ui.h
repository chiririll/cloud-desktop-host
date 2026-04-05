#ifndef CD_DEBUG_UI_H
#define CD_DEBUG_UI_H

#include "server.h"

extern "C" {
struct wlr_render_pass;
}

/* 
 * cd_render_debug_overlay — рендер диагностического HUD.
 * Вызывается из output.cpp в конце кадра.
 */
void cd_render_debug_overlay(struct cd_server *server, struct wlr_render_pass *pass);

#endif
