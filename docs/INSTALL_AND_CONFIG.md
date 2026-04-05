# Установка и настройка cloud-desktop-host

Цель: поднять стек **CDH → (KWin / Xwayland / Gamescope) → Sunshine → Moonlight** с согласованием разрешения и FPS.

Ниже — обобщённая схема; пути (`/home/user/...`, номер LXC) замените на свои.

## 1. Что должно быть установлено на хосте сессии

- Собранный **`cloud-desktop-host`** (см. [COMPILATION.md](COMPILATION.md))
- **Sunshine** (см. [LizardByte/Sunshine](https://github.com/LizardByte/Sunshine))
- Для режима **Desktop**: **KWin** (Wayland), **Plasma** (plasmashell и сопутствующие сервисы)
- Для **Steam GamepadUI** (отдельный сценарий): **Xwayland**, Steam с флагами из [`scripts/run-steam.sh`](../scripts/run-steam.sh)
- Для **Steam Deck Mode**: бинарник **gamescope** (nested), Steam с `-steamos3`, вспомогательные утилиты из `scripts/` и при необходимости **`gamescope-focus-daemon`**
- **PipeWire** + **WirePlumber** (аудио для Sunshine)
- Сессионный **D-Bus** (`DBUS_SESSION_BUS_ADDRESS`, `XDG_RUNTIME_DIR`)

## 2. Сокет Wayland и переменные окружения

Композитор по умолчанию создаёт сокет **`wayland-cd`** в `$XDG_RUNTIME_DIR`.

- Запуск Sunshine с захватом этого дисплея:  
  `WAYLAND_DISPLAY=wayland-cd`
- Скрипты в репозитории задают `XDG_RUNTIME_DIR`, `QT_*`, `XDG_CURRENT_DESKTOP` в зависимости от режима

## 3. Настройка Sunshine

### 3.1 Глобальная prep-команда (разрешение и FPS клиента)

Перед стартом стрима Sunshine может вызывать команду, которая:

1. Читает `SUNSHINE_CLIENT_WIDTH`, `SUNSHINE_CLIENT_HEIGHT`, `SUNSHINE_CLIENT_FPS`
2. Вызывает D-Bus **`SetOutputMode`** на `org.gamescope.Input`
3. При необходимости перезапускает элементы Plasma (`plasmashell --replace`)

Референс: [`scripts/sunshine-prep-cmd.sh`](../scripts/sunshine-prep-cmd.sh).

В веб-интерфейсе Sunshine укажите путь к этому скрипту (или обёртке) в настройках **Prep Commands** для **всех** приложений, если хотите единое поведение по FPS/разрешению.

### 3.2 Два профиля приложений (`apps`)

Файл-пример: [`configs/sunshine/apps.json`](../configs/sunshine/apps.json).

| `name` | Роль |
|--------|------|
| **Desktop** | Prep/undo для полного переключения в Plasma (KWin + стек) |
| **Steam Deck Mode** | Prep/undo для Gamescope + Steam `-steamos3` |

Скопируйте JSON в конфигурационный каталог Sunshine и поправьте **абсолютные пути** к скриптам (`/home/user/cloud-desktop-host/scripts/...`).

**Undo** важен: при отключении клиента Sunshine выполняет `undo`, чтобы убить лишние процессы и не оставлять висящий Gamescope/Plasma.

## 4. Moonlight на клиенте

- Выберите в списке приложений **Desktop** или **Steam Deck Mode** (как задано в `apps.json`)
- Задайте разрешение и частоту (например **1920×1080 @ 144 Hz** или **2560×1440 @ 144 Hz**, если сеть и энкодер вытягивают)
- Включите аппаратный декод на стороне клиента (NVIDIA/Intel/AMD — в зависимости от платформы)

После подключения Sunshine передаст размеры/FPS в prep-команды → **`SetOutputMode`** обновит режим виртуального output в CDH и цепочку presentation (см. раздел про refresh fixup в [архитектуре](Архитектура%20cloud-desktop-host%20%28CDH%29.md)).

## 5. Запуск стека (референс)

- **Быстрый тест без лишних логов:** [`scripts/run-nolog.sh`](../scripts/run-nolog.sh)  
  Поднимает D-Bus, PipeWire, CDH, при наличии — Sunshine. Plasma/KWin обычно приходят с prep при подключении Moonlight (зависит от вашей конфигурации Sunshine).

- **Steam GamepadUI (Xwayland):** [`scripts/run-steam.sh`](../scripts/run-steam.sh)  
  CDH с **`--no-auto-lock`**.

Убедитесь, что в скриптах путь **`HOST_BIN`** указывает на ваш собранный бинарник.

## 6. Настройка мыши (D-Bus / KCM Cloud Mouse)

CDH публикует интерфейсы **org.gamescope.InputDeviceManager** и **org.gamescope.InputDevice** (см. архитектурный документ). Через них настраиваются:

- ускорение и профиль указателя;
- **scrollFactor** (множитель скролла per-device);
- natural scroll, эмуляция средней кнопки и др.

Настройки могут сохраняться в **`~/.config/gamescope-input.conf`**.

## 7. Диагностика

- Лог CDH: часто `/tmp/cdh.log` (как в `run-nolog.sh`)
- Prep Sunshine: `/tmp/prep-cmd.log` (в `sunshine-prep-cmd.sh`)
- Включите **`--hud`** на композиторе для оверлея FPS/commit rate (см. [`src/debug_ui.cpp`](../src/debug_ui.cpp))
- **`--debug`** — подробные логи wlroots

## 8. NVIDIA / CUDA и Sunshine

Кодирование видео выполняет **Sunshine** (типично **NVENC** на GPU NVIDIA, с опорой на драйвер и Video Codec SDK). CDH отвечает за **корректный Wayland-композитинг и тайминг**. Убедитесь, что драйвер NVIDIA, `nvidia-smi` и настройки Sunshine согласованы (разрешение, битрейт, кодек H.264/H.265/AV1 — по возможностям железа).
