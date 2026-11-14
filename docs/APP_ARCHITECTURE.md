# Архитектура приложения cloud-desktop-host

`cloud-desktop-host` (CDH) - это специализированный headless Wayland-композитор для запуска полноценного Linux Desktop/Steam окружения внутри LXC-контейнера и стриминга результата через Sunshine/Moonlight без физического монитора и без DRM master.

Документ описывает архитектуру приложения на уровне продукта и основных модулей. Низкоуровневые детали реализации собраны в [Архитектуре CDH](./Архитектура%20cloud-desktop-host%20%28CDH%29.md).

---

## 1. Назначение

CDH решает задачу, к которой подводит статья: запустить облачный рабочий стол в Proxmox LXC так, чтобы:

- GPU оставался общим ресурсом для нескольких контейнеров и сервисов;
- не требовался физический монитор, EDID-заглушка или DRM master;
- Sunshine мог захватывать изображение стандартным Wayland-протоколом;
- рабочий стол KDE Plasma, XWayland-приложения, Steam и игры работали как в обычной сессии;
- разрешение и FPS подстраивались под параметры клиента Moonlight.

Ключевая идея: CDH не является полноценной оболочкой рабочего стола. Это минимальный композитор-захватчик: он предоставляет один виртуальный Wayland-output, принимает один полноэкранный клиент и делает его доступным для Sunshine через `wlr_screencopy`.

---

## 2. Контекст системы

```text
Moonlight client
    |
    | GameStream / RTP / RTSP
    v
Sunshine
    |
    | Wayland wlr_screencopy
    v
cloud-desktop-host
    |
    | Wayland socket: wayland-cd
    v
KWin + Plasma
или
Gamescope nested + Steam Deck Mode
```

Внешние роли:

| Участник | Роль |
|---|---|
| Proxmox host | Запускает LXC, держит драйвер NVIDIA и пробрасывает GPU/input-устройства |
| LXC container | Изолированная пользовательская среда Fedora/KDE/Sunshine/CDH |
| CDH | Headless Wayland-compositor, точка сборки кадра и ввода |
| KWin | Вложенный compositor для Desktop Mode |
| Gamescope | Вложенный compositor для Steam Deck Mode |
| Sunshine | Захват кадра, NVENC-кодирование, GameStream-сервер |
| Moonlight | Клиентский декодер и источник ввода |

---

## 3. Главные архитектурные принципы

| Принцип | Что означает |
|---|---|
| Headless first | CDH не использует DRM backend и не занимает DRM master |
| Один основной клиент | CDH рендерит один desktop toplevel: KWin, Gamescope или XWayland |
| Стандартный захват | Sunshine видит CDH как обычный wlroots compositor с `wlr_screencopy` |
| Минимум патчей | CDH заменяет цепочку патчей KWin/portal/Gamescope/Sunshine собственным маленьким компонентом |
| Damage-driven render | Кадр рендерится только при изменении контента, вводе или heartbeat |
| Dynamic mode | Разрешение и FPS меняются при подключении Moonlight через D-Bus `SetOutputMode` |
| Совместимость с KDE/Gamescope | CDH публикует только те Wayland-протоколы, которые нужны вложенным клиентам |

---

## 4. Развертывание

```text
Proxmox VE host
    NVIDIA kernel driver
    /dev/nvidia*, /dev/dri/renderD*, /dev/input/*, /dev/uinput
        |
        | LXC bind mounts + cgroup2 permissions
        v
LXC container
    Fedora
    NVIDIA userspace libraries
    PipeWire / WirePlumber
    KDE Plasma / KWin
    Gamescope / Steam
    Sunshine
    cloud-desktop-host
```

Контейнер не грузит свой модуль NVIDIA: ядро и драйвер живут на хосте. Внутри контейнера нужны пользовательские библиотеки той же версии, доступ к GPU render node, input-устройствам и D-Bus/PipeWire окружению.

---

## 5. Компоненты приложения

### 5.1 Core compositor

Файлы: `src/main.cpp`, `src/server.h`

Отвечает за:

- создание `wl_display`;
- запуск `wlr_headless_backend`;
- инициализацию GLES2-рендерера и allocator;
- регистрацию Wayland-протоколов;
- запуск event loop;
- heartbeat-таймер 500 мс.

`cd_server` - центральная структура состояния. В ней хранится core, output, XDG lifecycle, input state, D-Bus state и диагностический HUD.

### 5.2 Wayland protocols

Файл: `src/protocols.cpp`

CDH публикует минимальный набор протоколов, достаточный для KWin, Gamescope, XWayland и Sunshine:

- `wl_compositor`, `wl_subcompositor`, `wl_shm`;
- `xdg_wm_base`;
- `zwp_linux_dmabuf_v1`;
- `wlr_screencopy_v1`;
- `wp_presentation`;
- `wl_seat`;
- `zwp_relative_pointer_v1`;
- `zwp_pointer_constraints_v1`;
- `xdg_output_manager_v1`;
- `wp_viewporter`;
- `wp_single_pixel_buffer_v1`;
- clipboard/data device и вспомогательные протоколы KDE.

Отдельное решение - PID-фильтр для `xdg_wm_base`: этот global видят только `kwin_wayland`, `Xwayland` и `gamescope`. Sunshine не должен видеть XDG shell, иначе его GTK-трей может попытаться создать окно внутри CDH.

### 5.3 Output и render loop

Файл: `src/output.cpp`

CDH создает единственный виртуальный output:

```text
wlr_headless_backend -> wlr_output -> wlr_render_pass -> wlr_output_commit_state
```

Рендер запускается при трех событиях:

- вложенный клиент прислал новый `wl_surface.commit`;
- пришло событие ввода;
- сработал heartbeat.

Если клиента еще нет, CDH рисует тестовую RGB-анимацию. Если клиент есть, CDH рендерит его surface tree, затем опционально HUD.

Важное решение: present refresh fixup. Headless backend wlroots отдает `present.refresh = 0`, поэтому CDH перехватывает present event и подставляет реальный период кадра из текущего режима. Без этого KWin/Gamescope не получают корректные 90/120/144 Hz.

### 5.4 XDG lifecycle

Файл: `src/xdg.cpp`

CDH обрабатывает только один основной `xdg_toplevel`:

```text
new_toplevel -> initial commit -> configure fullscreen -> map -> render commits -> destroy
```

Первый toplevel становится рабочим столом. Все последующие считаются нецелевыми и игнорируются. Это осознанное упрощение: окнами управляет вложенный KWin/Gamescope, а CDH видит только итоговый fullscreen-клиент.

Дополнительно здесь реализован auto pointer lock: после map CDH отправляет виртуальный `Right Ctrl`, чтобы KWin активировал pointer lock и начал рисовать курсор прямо в framebuffer.

### 5.5 Input subsystem

Файлы: `src/input.cpp`, `src/dbus_input.cpp`, `src/dbus_input.h`

Так как headless backend wlroots не создает input devices, CDH сам подключается к `/dev/input` через standalone libinput.

Путь ввода:

```text
Moonlight
    -> Sunshine uinput devices
    -> /dev/input/event*
    -> libinput
    -> CDH
    -> wlr_seat
    -> KWin/Gamescope/XWayland
```

Есть два режима указателя:

| Режим | Для чего |
|---|---|
| FREE | Рабочий стол, меню, обычный курсор с абсолютной позицией |
| LOCKED | FPS-игры и pointer lock, где нужны относительные движения мыши |

Через D-Bus реализован интерфейс `org.gamescope.Input`, совместимый с настройками Gamescope/KDE. Он хранит параметры устройств и предоставляет главный метод управления режимом output: `SetOutputMode(width, height, fps)`.

### 5.6 Startup scripts

Файлы: `scripts/*.sh`, `configs/sunshine/apps.json`

Скрипты делят систему на базовый стек и режимы Moonlight:

```text
run.sh
    D-Bus
    PipeWire / WirePlumber / pipewire-pulse
    kactivitymanagerd
    CDH
    Sunshine
    (общие функции — scripts/lib.sh; логи — /tmp/cdhost-logs/<время>/)

Sunshine app: Desktop
    sunshine-prep-desktop.sh   (KWin + XWayland, kded6 / plasmashell / polkit)
    sunshine-undo-desktop.sh

Sunshine app: Steam Deck Mode
    sunshine-prep-gamescope.sh
    sunshine-undo-gamescope.sh
```

Sunshine передает в prep-скрипты `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT` и `SUNSHINE_CLIENT_FPS`. Скрипт вызывает D-Bus `SetOutputMode`, после чего запускает нужный пользовательский режим.

---

## 6. Runtime-сценарии

### 6.1 Desktop Mode

```text
1. Пользователь выбирает Desktop в Moonlight.
2. Sunshine запускает sunshine-prep-desktop.sh.
3. Скрипт вызывает SetOutputMode(W, H, FPS).
4. Если KWin не запущен, он стартует как Wayland-клиент CDH.
5. KWin поднимает Plasma и XWayland.
6. CDH принимает fullscreen surface от KWin.
7. Sunshine захватывает output CDH через wlr_screencopy.
8. Moonlight получает H.265/H.264 поток.
```

### 6.2 Steam Deck Mode

```text
1. Пользователь выбирает Steam Deck Mode в Moonlight.
2. Sunshine запускает sunshine-prep-gamescope.sh.
3. Скрипт завершает Plasma/KWin/старый Steam.
4. Вызывает SetOutputMode(W, H, FPS).
5. Запускает Gamescope nested как клиента CDH.
6. Внутри Gamescope стартует Steam -steamos3 -gamepadui.
7. CDH стримит итоговую surface Gamescope.
```

Gamescope в этой архитектуре не владеет DRM master. Он работает как обычный Wayland-клиент и нужен только для Steam Deck UI, MangoHud и игровых особенностей.

---

## 7. Потоки данных

### 7.1 Видеопоток

```text
KWin/Gamescope renders desktop/game
    -> wl_surface.commit(dmabuf)
    -> CDH render pass
    -> wlr_output present
    -> Sunshine wlr_screencopy
    -> NVENC encode
    -> network stream
    -> Moonlight decode
```

CDH не кодирует видео и не подменяет Sunshine. Его задача - быть корректным headless Wayland-output, который Sunshine умеет захватывать штатным путем.

### 7.2 Поток ввода

```text
Moonlight input
    -> Sunshine virtual input / uinput
    -> Linux input events
    -> libinput in CDH
    -> Wayland seat events
    -> KWin/Gamescope/XWayland
    -> application/game
```

Для игр CDH дополнительно отправляет relative pointer events, а pointer constraints переводят систему в LOCKED-режим.

### 7.3 Управляющий поток

```text
Moonlight profile parameters
    -> Sunshine env vars
    -> prep script
    -> busctl SetOutputMode
    -> CDH D-Bus handler
    -> wlr_output custom mode
    -> KWin/Gamescope configure
```

Так клиент Moonlight фактически управляет разрешением и частотой виртуального монитора.

---

## 8. Границы ответственности

| Компонент | Делает | Не делает |
|---|---|---|
| CDH | Виртуальный output, Wayland-протоколы, input bridge, timing, D-Bus control | Не является полноценным desktop shell, не кодирует видео |
| KWin | Управляет окнами Plasma/Desktop Mode | Не занимается стримингом |
| Gamescope | Дает Steam Deck Mode и игровой fullscreen-контейнер | Не владеет физическим GPU/DRM master |
| Sunshine | Захватывает кадры, кодирует NVENC, обслуживает Moonlight | Не управляет desktop lifecycle |
| Scripts | Оркестрируют запуск и переключение режимов | Не содержат графическую логику |

---

## 9. Ограничения

- Один основной fullscreen-клиент одновременно.
- Порядок запуска важен: D-Bus/PipeWire/CDH должны появиться до KWin/Gamescope/Sunshine.
- CDH ориентирован на wlroots/KDE/Gamescope-сценарий, а не на произвольный multi-window compositor.
- Steam Deck Mode имитирует окружение Deck частично: интерфейс работает, но аппаратно-зависимые функции Deck требуют отдельной эмуляции.
- Проект зависит от корректного проброса GPU, `/dev/input`, `/dev/uinput`, групп и прав в LXC.

---

## 10. Почему архитектура именно такая

Предыдущие варианты из статьи упирались в разные системные границы:

- X11 требовал монитор/EDID и конфликтовал за DRM master.
- KWin `--virtual` давал картинку, но ломал ввод и требовал патчить portals.
- KWin + VKMS давал ввод, но ломал zero-copy захват на NVIDIA.
- Форк Gamescope работал, но тащил большой чужой compositor ради маленькой части задачи.

CDH оставляет только нужную середину:

```text
headless Wayland output
+ KWin/Gamescope as nested client
+ wlr_screencopy for Sunshine
+ libinput bridge
+ D-Bus mode control
```

Именно поэтому финальная система меньше, понятнее и устойчивее к обновлениям, чем цепочка из патчей чужих компонентов.
