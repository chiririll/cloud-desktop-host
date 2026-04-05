/*
 * gamescope-focus-daemon.c — v2
 *
 * Минимальный X11 daemon — эмулирует подмножество steamcompmgr для
 * корректной работы Steam -steamos3 внутри KWin.
 *
 * v2: рекурсивный поиск окон, чтение GAMESCOPECTRL_BASELAYER_APPID,
 *     SubstructureNotify на все окна для отслеживания новых child'ов.
 *
 * Компиляция:
 *   gcc -O2 -o gamescope-focus-daemon gamescope-focus-daemon.c -lX11
 */

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>

static volatile int g_running = 1;

static void sighandler(int sig)
{
    (void)sig;
    g_running = 0;
}

/* ── Atoms ── */
static Atom aFocusedApp, aFocusedAppGfx, aFocusedWindow;
static Atom aInputCounter, aFocusableApps, aFocusableWins;
static Atom aSteamGame, aSteamBigPic, aGamescopePid;
static Atom aCtrlAppID; /* GAMESCOPECTRL_BASELAYER_APPID */

/* Прочитать uint32 property. Возвращает 0 если не найдено. */
static unsigned long get_prop_u32(Display *dpy, Window win, Atom prop)
{
    Atom type;
    int fmt;
    unsigned long nitems, after;
    unsigned char *data = NULL;
    unsigned long val = 0;

    if (XGetWindowProperty(dpy, win, prop, 0, 1, False, XA_CARDINAL,
                           &type, &fmt, &nitems, &after, &data) == Success) {
        if (data && nitems > 0 && fmt == 32)
            val = *(unsigned long *)data;
        if (data) XFree(data);
    }
    return val;
}

/* Прочитать массив uint32. Возвращает количество. */
static int get_prop_array(Display *dpy, Window win, Atom prop,
                          unsigned long *out, int max)
{
    Atom type;
    int fmt;
    unsigned long nitems, after;
    unsigned char *data = NULL;
    int count = 0;

    if (XGetWindowProperty(dpy, win, prop, 0, max, False, XA_CARDINAL,
                           &type, &fmt, &nitems, &after, &data) == Success) {
        if (data && fmt == 32) {
            unsigned long *arr = (unsigned long *)data;
            for (unsigned long i = 0; i < nitems && (int)i < max; i++)
                out[count++] = arr[i];
        }
        if (data) XFree(data);
    }
    return count;
}

static void set_prop_u32(Display *dpy, Window root, Atom prop, unsigned long v)
{
    XChangeProperty(dpy, root, prop, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)&v, v != 0 ? 1 : 0);
}

static void set_prop_array(Display *dpy, Window root, Atom prop,
                           unsigned long *v, int n)
{
    XChangeProperty(dpy, root, prop, XA_CARDINAL, 32, PropModeReplace,
                    (unsigned char *)v, n);
}

/* ── Рекурсивный поиск окон с STEAM_GAME ── */
typedef struct {
    unsigned long appid;
    Window        win;
} GameWindow;

static int g_gameCount = 0;
static GameWindow g_games[256];

static void find_game_windows_recursive(Display *dpy, Window win, int depth)
{
    if (depth > 5 || g_gameCount >= 256) return;

    unsigned long appid = get_prop_u32(dpy, win, aSteamGame);
    if (appid != 0) {
        g_games[g_gameCount].appid = appid;
        g_games[g_gameCount].win   = win;
        g_gameCount++;
    }

    Window root_ret, parent_ret;
    Window *children = NULL;
    unsigned int nchildren = 0;

    if (XQueryTree(dpy, win, &root_ret, &parent_ret, &children, &nchildren)) {
        for (unsigned int i = 0; i < nchildren && g_gameCount < 256; i++)
            find_game_windows_recursive(dpy, children[i], depth + 1);
        if (children) XFree(children);
    }
}

static void refresh_game_windows(Display *dpy, Window root)
{
    g_gameCount = 0;
    find_game_windows_recursive(dpy, root, 0);
}

/* Найти окно по appid */
static Window find_window_by_appid(unsigned long appid)
{
    for (int i = 0; i < g_gameCount; i++) {
        if (g_games[i].appid == appid)
            return g_games[i].win;
    }
    return None;
}

/* ── Main ── */
int main(void)
{
    signal(SIGINT, sighandler);
    signal(SIGTERM, sighandler);

    Display *dpy = XOpenDisplay(NULL);
    if (!dpy) {
        fprintf(stderr, "[focus-daemon] Cannot open DISPLAY\n");
        return 1;
    }

    int screen = DefaultScreen(dpy);
    Window root = RootWindow(dpy, screen);

    /* Intern atoms */
    aFocusedApp    = XInternAtom(dpy, "GAMESCOPE_FOCUSED_APP", False);
    aFocusedAppGfx = XInternAtom(dpy, "GAMESCOPE_FOCUSED_APP_GFX", False);
    aFocusedWindow = XInternAtom(dpy, "GAMESCOPE_FOCUSED_WINDOW", False);
    aInputCounter  = XInternAtom(dpy, "GAMESCOPE_INPUT_COUNTER", False);
    aFocusableApps = XInternAtom(dpy, "GAMESCOPE_FOCUSABLE_APPS", False);
    aFocusableWins = XInternAtom(dpy, "GAMESCOPE_FOCUSABLE_WINDOWS", False);
    aSteamGame     = XInternAtom(dpy, "STEAM_GAME", False);
    aSteamBigPic   = XInternAtom(dpy, "STEAM_BIGPICTURE", False);
    aGamescopePid  = XInternAtom(dpy, "GAMESCOPE_PID", False);
    aCtrlAppID     = XInternAtom(dpy, "GAMESCOPECTRL_BASELAYER_APPID", False);

    /* GAMESCOPE_PID — Steam проверяет наличие */
    unsigned long pid = (unsigned long)getpid();
    set_prop_u32(dpy, root, aGamescopePid, pid);

    /* Подписаться на события root */
    XSelectInput(dpy, root,
                 SubstructureNotifyMask |
                 PropertyChangeMask |
                 FocusChangeMask);

    unsigned long inputCounter = 0;
    unsigned long lastFocusedApp = 0;

    /* Начальная инициализация: Steam = appid 769 */
    unsigned long steamAppId = 769;
    set_prop_u32(dpy, root, aFocusedApp, steamAppId);
    set_prop_u32(dpy, root, aFocusedAppGfx, steamAppId);
    set_prop_u32(dpy, root, aInputCounter, inputCounter);
    XFlush(dpy);

    fprintf(stderr, "[focus-daemon] v2 started on DISPLAY=%s\n",
            XDisplayString(dpy));

    while (g_running) {
        int dirty = 0;

        while (XPending(dpy) > 0) {
            XEvent ev;
            XNextEvent(dpy, &ev);

            if (ev.type == PropertyNotify) {
                /* Steam обновил GAMESCOPECTRL_BASELAYER_APPID → читаем */
                if (ev.xproperty.atom == aCtrlAppID) {
                    dirty = 1;
                }
            }

            if (ev.type == MapNotify || ev.type == UnmapNotify ||
                ev.type == CreateNotify || ev.type == DestroyNotify ||
                ev.type == ConfigureNotify || ev.type == ReparentNotify) {
                dirty = 1;
            }

            if (ev.type == FocusIn || ev.type == FocusOut) {
                dirty = 1;
            }
        }

        if (!dirty) {
            usleep(50000); /* 50ms idle poll */
            continue;
        }

        /* Пересканировать дерево окон */
        refresh_game_windows(dpy, root);

        /* Прочитать что Steam хочет фокусировать */
        unsigned long ctrl_apps[16];
        int ctrl_count = get_prop_array(dpy, root, aCtrlAppID,
                                        ctrl_apps, 16);

        /* Определить фокусное приложение.
         * Приоритет: первый appid из GAMESCOPECTRL_BASELAYER_APPID,
         * который имеет окно. Если нет — Steam (769). */
        unsigned long focusedApp = steamAppId;
        Window focusedWin = None;

        for (int i = 0; i < ctrl_count; i++) {
            if (ctrl_apps[i] == 769) continue; /* пропускаем Steam */
            Window w = find_window_by_appid(ctrl_apps[i]);
            if (w != None) {
                focusedApp = ctrl_apps[i];
                focusedWin = w;
                break;
            }
        }

        /* Если не нашли игровое окно, берём X11 фокус */
        if (focusedWin == None) {
            int revert;
            XGetInputFocus(dpy, &focusedWin, &revert);
            if (focusedWin == PointerRoot || focusedWin == None) {
                focusedWin = root;
            }
            /* Проверяем STEAM_GAME на фокусном окне */
            unsigned long appid = get_prop_u32(dpy, focusedWin, aSteamGame);
            if (appid != 0) {
                focusedApp = appid;
            }
        }

        if (focusedApp != lastFocusedApp) {
            fprintf(stderr, "[focus-daemon] Focus → appid=%lu win=0x%lx "
                    "(games=%d, ctrl=%d)\n",
                    focusedApp, focusedWin, g_gameCount, ctrl_count);
            lastFocusedApp = focusedApp;
        }

        /* Обновляем атомы */
        set_prop_u32(dpy, root, aFocusedApp, focusedApp);
        set_prop_u32(dpy, root, aFocusedAppGfx, focusedApp);
        set_prop_u32(dpy, root, aFocusedWindow, (unsigned long)focusedWin);

        inputCounter++;
        set_prop_u32(dpy, root, aInputCounter, inputCounter);

        /* Focusable lists */
        unsigned long app_ids[256];
        unsigned long win_ids[256];
        for (int i = 0; i < g_gameCount; i++) {
            app_ids[i] = g_games[i].appid;
            win_ids[i] = (unsigned long)g_games[i].win;
        }
        set_prop_array(dpy, root, aFocusableApps, app_ids, g_gameCount);
        set_prop_array(dpy, root, aFocusableWins, win_ids, g_gameCount);

        XFlush(dpy);
    }

    /* Очистка */
    set_prop_u32(dpy, root, aFocusedApp, 0);
    set_prop_u32(dpy, root, aFocusedAppGfx, 0);
    set_prop_u32(dpy, root, aFocusedWindow, 0);
    set_prop_u32(dpy, root, aGamescopePid, 0);
    XFlush(dpy);
    XCloseDisplay(dpy);
    fprintf(stderr, "[focus-daemon] Stopped\n");
    return 0;
}
