# cloud-desktop-host

**cloud-desktop-host** (CDH) — кастомный headless Wayland-композитор, который превращает GPU-сервер или LXC-контейнер на Proxmox в полноценный облачный рабочий стол: Plasma/KDE, игры, Steam с GamepadUI и Steam Deck Mode — всё стримится на любое устройство через **Moonlight** с задержкой уровня локальной игры.

```
  ┌──────────────────────────────────────────────────────────────────┐
  │  Клиент (Moonlight)       Любое устройство: ПК, планшет, TV     │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │  H.265 / NVENC  ≤ 144 Hz
  ┌────────────────────────────────┴─────────────────────────────────┐
  │  Sunshine                      захват + кодирование              │
  └────────────────────────────────┬─────────────────────────────────┘
                                   │  wlr_screencopy / wayland-cd
  ┌────────────────────────────────┴─────────────────────────────────┐
  │  cloud-desktop-host (CDH)      headless Wayland compositor       │
  │  wlroots 0.18.3 · GLES2 · GBM allocator · D-Bus gamescope.Input │
  └──────┬────────────────────────────────────────────────┬──────────┘
         │  wayland-cd                                    │  wayland-cd
  ┌──────┴──────────┐                            ┌────────┴──────────┐
  │  KWin + Plasma  │  ← Desktop Mode            │  Gamescope nested │  ← Steam Deck Mode
  │  kwin_wayland   │                            │  + Steam -steamos3│
  └─────────────────┘                            └───────────────────┘
```

---

## Для чего это нужно

Типичный Moonlight-стрим работает через **Sunshine**, который захватывает либо KMS (физический экран), либо X11, либо Wayland через `wlr_screencopy`. Проблема: в **LXC-контейнере на Proxmox нет DRM Master** — Sunshine не может захватить экран стандартными способами.

CDH решает это элегантно: создаёт **виртуальный Wayland-output** (headless, без DRM), запускает на нём полноценный рабочий стол, и Sunshine захватывает кадры напрямую через Wayland-протокол `wlr_screencopy_v1`. Никаких костылей с виртуальными мониторами, VNC или VirtualGL.

**Где применяется:**

- **Облачный игровой ПК** — GPU-сервер (RTX 3090 и т.п.) в LXC, Moonlight на любом клиенте в локальной сети.
- **Удалённый рабочий стол с ускорением** — Plasma через KWin, с полным GPU-ускорением, clipboard, звуком через PipeWire.
- **Облачный Steam Deck** — Steam Big Picture / Deck Mode через nested Gamescope с MangoHud, FSR, поддержкой геймпада.
- **Headless-рендеринг в VM/LXC** — без каких-либо изменений в хост-системе, только проброс GPU через `lxc.mount.entry`.

---

## Три режима в одном стеке

Переключение между режимами происходит автоматически через Sunshine prep/undo скрипты при подключении клиента. Никакого ручного вмешательства не требуется.

| Режим | Что запускается | Для чего |
|-------|----------------|----------|
| **Desktop** | KWin + Plasma (KDE) | Полноценный рабочий стол: браузер, приложения, игры через Steam |
| **Steam Deck Mode** | nested Gamescope + Steam `-steamos3` | Steam Deck UI, MangoHud, FSR/NIS, геймпад |
| **Steam GamepadUI** | Xwayland + Steam `-gamepadui` | Big Picture Mode без Gamescope |

---

## Архитектура: что внутри CDH

CDH — это около **двух тысяч строк C++17** на базе [wlroots 0.18.3](https://gitlab.freedesktop.org/wlroots/wlroots). Основные авторские решения:

### Headless output без DRM

Compositor создаёт виртуальный output через `wlr_headless_backend`. Разрешение и частота задаются динамически через D-Bus и могут меняться при каждом подключении Moonlight — от 720p@60 до 4K@144.

### Адаптивная частота и present refresh fixup

При подключении Moonlight Sunshine передаёт `SUNSHINE_CLIENT_WIDTH/HEIGHT/FPS` → prep-скрипт вызывает **`SetOutputMode(w, h, fps)`** через D-Bus → CDH меняет режим output «на лету».

**Нюанс headless backend:** wlroots отправляет `present` event с `refresh=0`. Без исправления KWin и Gamescope не видят смену частоты и остаются на 60 Hz. CDH **вставляет свой listener в HEAD цепочки** — до wlr_presentation — и подставляет корректный период кадра из `cur_refresh`. Это ключевое архитектурное решение, позволяющее работать на 144 Hz без патча wlroots.

### Damage-driven рендер

Рендер происходит **только** при новом коммите от KWin/Gamescope, событии ввода или принудительном heartbeat (раз в 500 мс). В режиме простоя GPU почти не нагружается — даже на 144 Hz при статичном рабочем столе нагрузка минимальна.

Heartbeat нужен для предотвращения starvation: без периодических `frame_done` KWin зависает, а Sunshine закрывает сессию по таймауту.

### Standalone libinput + D-Bus org.gamescope.Input

Headless backend wlroots не создаёт input-устройств — CDH подключается к `/dev/input` напрямую через **standalone libinput** (udev/seat0). Ввод от Sunshine (виртуальная мышь/клавиатура через `/dev/uinput`) обрабатывается и пробрасывается в `wlr_seat` → KWin/Xwayland.

Поверх libinput реализован **D-Bus сервис `org.gamescope.Input`** — точная копия интерфейса Gamescope. Это даёт:
- совместимость с **KCM Cloud Mouse** (KDE модуль настройки мыши);
- per-device `scrollFactor` (default 8.0) с сохранением в `~/.config/gamescope-input.conf`;
- профили ускорения, natural scroll, middle button emulation.

### PID-фильтр для xdg_wm_base

`xdg_wm_base` виден **только** процессам `kwin_wayland`, `Xwayland` или `gamescope`. Sunshine использует GTK-трей и при виде `xdg_wm_base` пытается создать toplevel-окно → CDH зависает. Фильтр по PID/comm решает это без патча Sunshine.

### Автоматический pointer lock

При маппинге desktop surface CDH ждёт 200 мс и отправляет виртуальный `RCTRL press+release`. KWin реагирует вызовом `togglePointerLock()` → `zwp_locked_pointer_v1` активируется → KWin начинает рисовать курсор в framebuffer, и он виден в стриме. Без этого курсор отрисовывается поверх захвата как overlay и не попадает в Moonlight.

---

## Производительность

| Параметр | Значение |
|----------|----------|
| Энкодер | NVENC H.265 (через Sunshine + NVIDIA Video Codec SDK) |
| Максимальная частота | 144 Hz (валидация SetOutputMode: до 360 fps) |
| Нагрузка на GPU (idle) | минимальная — damage-driven render + heartbeat 2 fps |
| Нагрузка на GPU (игра) | определяется игрой + NVENC encode; CDH добавляет ~0 |
| Задержка композитора | 0 дополнительных копий: KWin → dmabuf → CDH → wlr_screencopy → NVENC |
| Декод на клиенте | NVDEC / VAAPI / D3D11VA в Moonlight |

---

## Структура репозитория

```
cloud-desktop-host/
├── src/                         # ~2000 строк C++17 — сам CDH
│   ├── main.cpp                 # точка входа, event loop, heartbeat timer
│   ├── server.h                 # центральная структура cd_server
│   ├── protocols.cpp            # 20 Wayland-протоколов + PID-фильтр
│   ├── output.cpp               # рендер-цикл, damage-driven, present fixup
│   ├── xdg.cpp                  # XDG Shell lifecycle, auto pointer lock
│   ├── input.cpp                # standalone libinput, FREE/LOCKED режимы
│   ├── dbus_input.cpp           # D-Bus org.gamescope.Input (730 строк)
│   └── debug_ui.cpp             # HUD overlay с растровым шрифтом
├── scripts/
│   ├── run.sh                   # полный запуск стека (Desktop)
│   ├── run-nolog.sh             # быстрый запуск без логов
│   ├── run-steam.sh             # Steam GamepadUI (--no-auto-lock)
│   ├── sunshine-prep-desktop.sh # prep: KWin + Plasma
│   ├── sunshine-prep-gamescope.sh # prep: Gamescope + Steam -steamos3
│   ├── sunshine-prep-cmd.sh     # prep: SetOutputMode + plasmashell --replace
│   ├── sunshine-undo-desktop.sh # undo: kill Plasma stack
│   └── sunshine-undo-gamescope.sh # undo: kill Gamescope + Steam + Xwayland
├── tools/
│   └── gamescope-focus-daemon.c # X11 daemon: эмуляция steamcompmgr для KWin
├── configs/
│   └── sunshine/apps.json       # два профиля: Desktop + Steam Deck Mode
├── meson.build                  # сборка CDH
└── subprojects/
    ├── wlroots/   @ 0.18.3      # git submodule — freedesktop.org
    ├── gamescope/ @ 3.16.14.5   # git submodule — ValveSoftware
    └── sunshine/  @ v2026.*     # git submodule — LizardByte
```

---

## Документация

| Документ | Что внутри |
|----------|-----------|
| [Архитектура приложения](docs/APP_ARCHITECTURE.md) | Верхнеуровневая архитектура: контекст, компоненты, runtime-сценарии, потоки данных, границы ответственности |
| [Архитектура CDH](docs/Архитектура%20cloud-desktop-host%20%28CDH%29.md) | Детальное описание всех модулей, протоколов, рендер-цикла, потоков данных, ключевых решений |
| [docs/BUILD.md](docs/BUILD.md) | Сборка CDH, Gamescope и Sunshine (CMake/Meson, CUDA, Node/npm) |
| [docs/INSTALL_AND_CONFIG.md](docs/INSTALL_AND_CONFIG.md) | Установка: хост PVE (LXC conf, NVIDIA, cgroup2) и контейнер (Fedora, Sunshine, скрипты) |
| [docs/SUBPROJECTS.md](docs/SUBPROJECTS.md) | Git submodules: wlroots, Gamescope, Sunshine — версии и управление |

---

## Быстрый старт

```bash
# Клонировать со всеми субмодулями
git clone --recurse-submodules https://github.com/wolfram0108/cloud-desktop-host.git
cd cloud-desktop-host

# Собрать CDH (wlroots компилируется как subproject)
meson setup build
ninja -C build

# Запустить стек (Desktop режим)
./scripts/run.sh
```

Подробности по зависимостям — [docs/BUILD.md](docs/BUILD.md).  
Настройка LXC и GPU passthrough — [docs/INSTALL_AND_CONFIG.md](docs/INSTALL_AND_CONFIG.md).

---

## Зависимости и субмодули

| Субмодуль | Upstream | Версия |
|-----------|----------|--------|
| `subprojects/wlroots` | [freedesktop.org](https://gitlab.freedesktop.org/wlroots/wlroots) | 0.18.3 |
| `subprojects/gamescope` | [ValveSoftware](https://github.com/ValveSoftware/gamescope) | 3.16.14.5 |
| `subprojects/sunshine` | [LizardByte](https://github.com/LizardByte/Sunshine) | v2026.* |

Системные зависимости CDH: `wayland-server`, `wayland-protocols ≥1.35`, GLES2, `libinput`, `libudev`, `libsystemd`, `libdrm`, GBM, `pixman`.

---

## Лицензии

- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) — MIT
- [Gamescope](https://github.com/ValveSoftware/gamescope) — MIT (и зависимости Valve)
- [Sunshine](https://github.com/LizardByte/Sunshine) — GPL-3.0

Код в `src/`, `scripts/`, `tools/` — добавьте `LICENSE` в корень репозитория.
