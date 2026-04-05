/*
 * mouse-test — Визуальный тест relative mouse motion.
 * Скрывает курсор (как FPS-игра), рисует перекрестие.
 * Если перекрестие двигается при движении мыши — mouse motion работает.
 * ESC для выхода.
 *
 * Сборка: gcc -o mouse-test mouse-test.c $(sdl2-config --cflags --libs)
 * Запуск: ./mouse-test
 */
#include <SDL.h>
#include <stdio.h>
#include <stdlib.h>

#define WIN_W 800
#define WIN_H 600

int main(int argc, char *argv[]) {
    (void)argc; (void)argv;

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        fprintf(stderr, "SDL_Init: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Window *win = SDL_CreateWindow(
        "Mouse Test (ESC=quit)",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WIN_W, WIN_H, SDL_WINDOW_SHOWN);
    if (!win) {
        fprintf(stderr, "SDL_CreateWindow: %s\n", SDL_GetError());
        return 1;
    }

    SDL_Renderer *ren = SDL_CreateRenderer(win, -1,
        SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);
    if (!ren) {
        fprintf(stderr, "SDL_CreateRenderer: %s\n", SDL_GetError());
        return 1;
    }

    /* Скрываем курсор + включаем relative mode — как в FPS-игре */
    SDL_SetRelativeMouseMode(SDL_TRUE);

    float cx = WIN_W / 2.0f;
    float cy = WIN_H / 2.0f;
    int running = 1;

    printf("Mouse test started. Move mouse — crosshair should follow.\n");
    printf("Cursor is HIDDEN (game mode). Press ESC to quit.\n");

    while (running) {
        SDL_Event ev;
        while (SDL_PollEvent(&ev)) {
            switch (ev.type) {
            case SDL_QUIT:
                running = 0;
                break;
            case SDL_KEYDOWN:
                if (ev.key.keysym.sym == SDLK_ESCAPE)
                    running = 0;
                break;
            case SDL_MOUSEMOTION:
                cx += ev.motion.xrel;
                cy += ev.motion.yrel;
                /* Clamp */
                if (cx < 0) cx = 0;
                if (cy < 0) cy = 0;
                if (cx >= WIN_W) cx = WIN_W - 1;
                if (cy >= WIN_H) cy = WIN_H - 1;
                break;
            }
        }

        /* Чёрный фон */
        SDL_SetRenderDrawColor(ren, 20, 20, 30, 255);
        SDL_RenderClear(ren);

        /* Перекрестие (зелёное) */
        int ix = (int)cx, iy = (int)cy;
        SDL_SetRenderDrawColor(ren, 0, 255, 80, 255);
        SDL_RenderDrawLine(ren, ix - 20, iy, ix + 20, iy);
        SDL_RenderDrawLine(ren, ix, iy - 20, ix, iy + 20);

        /* Центральная точка (красная) */
        SDL_Rect dot = { ix - 2, iy - 2, 5, 5 };
        SDL_SetRenderDrawColor(ren, 255, 60, 60, 255);
        SDL_RenderFillRect(ren, &dot);

        /* Координаты текстом нет (SDL2 без SDL_ttf),
           но printf в консоль для диагностики */

        SDL_RenderPresent(ren);
    }

    printf("Exiting. Final position: %.0f, %.0f\n", cx, cy);
    SDL_DestroyRenderer(ren);
    SDL_DestroyWindow(win);
    SDL_Quit();
    return 0;
}
