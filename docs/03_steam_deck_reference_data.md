# Эталонные данные реального Steam Deck — Game Mode

Данные собраны **16.03.2026** по SSH с реального Steam Deck (192.168.1.120) в Game Mode.
Цель — reference для отладки Performance Overlay в cloud-desktop-host.

---

## 1. Версии компонентов

| Компонент | Steam Deck (эталон) | CDH LXC 120 (наш) | Совместимость |
|---|---|---|---|
| ОС | SteamOS (Arch, holo) | Fedora 43 | — |
| Gamescope | **3.16.14.5-1** | **3.16.20-8-gcebc073+** | ⚠️ Наш **новее** |
| MangoHud / MangoApp | **0.8.1-r103** (g10479eb) | **0.8.2** (из Fedora repos) | ❌ Struct mismatch |
| GLFW | `glfw-x11` (Arch package) | `glfw` (Fedora) | ✅ |
| GPU Driver | AMD (встроенный APU) | NVIDIA 580.126.09 | ⚠️ Разные |

---

## 2. Процессы в Game Mode

```
# Gamescope (DRM backend — прямой доступ к дисплею)
gamescope --generate-drm-mode fixed \
  --xwayland-count 2 \
  -w 1280 -h 800 \
  --default-touch-mode 4 \
  --hide-cursor-delay 3000 \
  --max-scale 2 \
  --fade-out-duration 200 \
  --cursor-scale-height 720 \
  -e \
  -R /run/user/1000/gamescope.NASthnQ/startup.socket \
  -T /run/user/1000/gamescope.NASthnQ/stats.pipe \
  -O *,eDP-1

# MangoApp (PID 24128)
/usr/bin/mangoapp
```

> [!IMPORTANT]
> На реальном Deck Gamescope использует **DRM backend** (`--generate-drm-mode`, `-O *,eDP-1`),
> а у нас — **Wayland nested backend** (`--backend wayland`). Это фундаментальное различие:
> DRM backend имеет полный `GetModes()` / `GetValidDynamicRefreshRates()`,
> а Wayland backend возвращает **пустой span**.

---

## 3. Environment Variables MangoApp

```bash
# Собрано из /proc/24128/environ на Steam Deck
DESKTOP_SESSION=gamescope-wayland
DISPLAY=:0
GAMESCOPE_WAYLAND_DISPLAY=gamescope-0
MANGOHUD_CONFIGFILE=/run/user/1000/gamescope.NASthnQ/mangohud.config
STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND=1
STEAM_DISPLAY_REFRESH_LIMITS=40,60
STEAM_MANGOAPP_HORIZONTAL_SUPPORTED=1
STEAM_MANGOAPP_PRESETS_SUPPORTED=1
STEAM_MULTIPLE_XWAYLANDS=1
STEAM_USE_DYNAMIC_VRS=1
STEAM_USE_MANGOAPP=1
vk_xwayland_wait_ready=false
```

### Сравнение ENV с CDH

| Переменная | Steam Deck | CDH | Примечание |
|---|---|---|---|
| `DISPLAY` | `:0` | `:0` | ✅ |
| `GAMESCOPE_WAYLAND_DISPLAY` | `gamescope-0` | `gamescope-0` | ✅ |
| `MANGOHUD_CONFIGFILE` | Gamescope temp path | `/tmp/mangohud-gamescope.conf` | ✅ |
| `STEAM_USE_MANGOAPP` | `1` | `1` | ✅ |
| `STEAM_MANGOAPP_PRESETS_SUPPORTED` | `1` | `1` | ✅ |
| `STEAM_MANGOAPP_HORIZONTAL_SUPPORTED` | `1` | `1` | ✅ |
| `STEAM_DISABLE_MANGOAPP_ATOM_WORKAROUND` | `1` | `1` | ✅ |
| `STEAM_DISPLAY_REFRESH_LIMITS` | `40,60` | **отсутствует** | ⚠️ |
| `STEAM_USE_DYNAMIC_VRS` | `1` | **отсутствует** | — |
| `STEAM_DECK` | **отсутствует** | `1` | ⚠️ CDH добавляет |

> [!NOTE]
> `STEAM_DISPLAY_REFRESH_LIMITS=40,60` — Gamescope **DRM backend** устанавливает
> этот env на основе реальных display modes. Wayland backend этого **не делает**.

---

## 4. MangoHud Config

### Steam Deck (эталон)

```ini
# /run/user/1000/gamescope.NASthnQ/mangohud.config
# Permissions: -rw-r--r-- (644) — ЗАПИСЫВАЕМЫЙ
control=mangohud
fsr_steam_sharpness=5
nis_steam_sharpness=10
preset=2
```

### CDH (наш)

```ini
# /tmp/mangohud-gamescope.conf
# Permissions: -r--r--r-- (444) — READONLY!
control=mangohud
```

> [!CAUTION]
> **Критическое различие**: на Deck конфиг **записываемый** (644). Steam дописывает
> `fsr_steam_sharpness`, `nis_steam_sharpness` и **`preset=N`** при изменении настроек.
> У нас `chmod 444` блокирует запись → Steam не может установить preset →
> MangoApp не активирует overlay.

---

## 5. X11 атомы (root window `:0`)

### Полный список атомов Steam Deck

```
GAMESCOPE_COMPOSITE_FORCE(CARDINAL) = 0
GAMESCOPE_COMPOSITE_DEBUG(CARDINAL) = 0
GAMESCOPE_ALLOW_TEARING(CARDINAL) = 0
GAMESCOPE_COLOR_MURA_CORRECTION_DISABLED(CARDINAL) = 0
GAMESCOPE_DISPLAY_DYNAMIC_REFRESH_BASED_ON_GAME_PRESENCE(CARDINAL) = 1
GAMESCOPE_RESHADE_TECHNIQUE_IDX(CARDINAL) = 0
GAMESCOPE_RESHADE_EFFECT(UTF8_STRING) = 
GAMESCOPE_DEBUG_HDR_HEATMAP(CARDINAL) = 0
GAMESCOPE_INPUT_COUNTER                          — отсутствует на Deck
GAMESCOPECTRL_BASELAYER_WINDOW(CARDINAL) = 0
GAMESCOPECTRL_BASELAYER_APPID(CARDINAL) = 413091, 769
STEAM_SCREEN_SCALE(CARDINAL) = 4294967295
STEAM_TOUCH_CLICK_MODE(CARDINAL) = 4             — отсутствует у CDH
GDK_VISUALS(INTEGER) = 708, 575
GAMESCOPE_DISPLAY_HDR_ENABLED(CARDINAL) = 1
GAMESCOPE_FSR_SHARPNESS(CARDINAL) = 0            — отсутствует у CDH
GAMESCOPE_NEW_SCALING_SCALER(CARDINAL) = 2
GAMESCOPE_NEW_SCALING_FILTER(CARDINAL) = 2
GAMESCOPE_FPS_LIMIT(CARDINAL) = 60
GAMESCOPE_DYNAMIC_REFRESH(CARDINAL) = 60         — отсутствует у CDH
GAMESCOPE_DYNAMIC_REFRESH_IN_STEAM(CARDINAL) = 0
GAMESCOPE_SDR_ON_HDR_CONTENT_BRIGHTNESS(CARDINAL) = 1128965079
GAMESCOPE_HDR_ON_SDR_TONEMAP_OPERATOR(CARDINAL) = 0
GAMESCOPE_HDR_INPUT_GAIN(CARDINAL) = 1065353216  — отсутствует у CDH
GAMESCOPE_SDR_INPUT_GAIN(CARDINAL) = 1065353216  — отсутствует у CDH
GAMESCOPE_DISPLAY_VIRTUAL_WHITE(CARDINAL) = ...  — отсутствует у CDH
GAMESCOPE_COLOR_SDR_GAMUT_WIDENESS(CARDINAL) = ...
GAMESCOPE_COLOR_NIGHT_MODE(CARDINAL) = ...
GAMESCOPE_HDR_OUTPUT_FEEDBACK(CARDINAL) = 0
GAMESCOPE_DISPLAY_EDID_PATH(UTF8_STRING) = "/home/deck/.config/gamescope/edid.bin"
GAMESCOPE_DISPLAY_IS_EXTERNAL(CARDINAL) = 0
GAMESCOPE_VRR_ENABLED(CARDINAL) = 0
GAMESCOPE_DISPLAY_REFRESH_RATE_FEEDBACK(CARDINAL) = 60
GAMESCOPE_VRR_FEEDBACK(CARDINAL) = 0
GAMESCOPE_DISPLAY_SUPPORTS_HDR(CARDINAL) = 0
GAMESCOPE_VRR_CAPABLE(CARDINAL) = 0
GAMESCOPE_KEYBOARD_FOCUS_DISPLAY(CARDINAL) = 12346, 0, 78
GAMESCOPE_MOUSE_FOCUS_DISPLAY(CARDINAL) = 12346, 0, 78
GAMESCOPE_FOCUS_DISPLAY(CARDINAL) = 12346, 0, 78
GAMESCOPE_FOCUSED_WINDOW(CARDINAL) = 37748789
GAMESCOPE_FOCUSED_APP_GFX(CARDINAL) = 769
GAMESCOPE_FOCUSED_APP(CARDINAL) = 769
GAMESCOPE_FOCUSABLE_WINDOWS(CARDINAL) = 37748789, 769, 24715
GAMESCOPE_FOCUSABLE_APPS(CARDINAL) = 769
GAMESCOPE_CURSOR_VISIBLE_FEEDBACK(CARDINAL) = 0
GAMESCOPE_XWAYLAND_SERVER_ID(CARDINAL) = 0
```

### Атомы, которые ОТСУТСТВУЮТ на обоих

```
GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL  — НЕТ ни на Deck, ни у CDH
GAMESCOPE_DISPLAY_MANGOHUD_PRESET     — НЕТ (устанавливается MangoApp окном)
GAMESCOPE_EXTERNAL_OVERLAY            — НЕТ на root window (атом на окне MangoApp)
GAMESCOPE_PID                         — есть у CDH, отсутствует на Deck root
```

> [!IMPORTANT]
> `GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL` **отсутствует и на реальном Deck**.
> Значит Performance overlay **не зависит** от mode list.

---

## 6. SysV IPC Message Queue

```
# Steam Deck
key        msqid    owner  perms  used-bytes  messages
0xffffffff 0        deck   666    0           0

Message Queue msqid=0
lspid=24050     lrpid=24201
send_time=Mon Mar 16 17:07:56 2026
rcv_time=Mon Mar 16 17:07:56 2026
change_time=Sun Feb  8 00:27:23 2026
```

### Наблюдения

- `ftok("mangoapp", 65)` возвращает **-1 (0xffffffff)** и на Deck, и у нас — файл `mangoapp` не существует в CWD
- На Deck CWD MangoApp = `/home/deck`, у CDH = `/home/user/cloud-desktop-host/scripts`
- Key 0xffffffff используется обоими сторонами — это **по дизайну** (ошибка ftok игнорируется)
- `change_time = Feb 8` — очередь создана давно и **переиспользуется** между сессиями

---

## 7. Struct `mangoapp_msg_v1` — несовместимость

### Gamescope 3.16.20 (наш, из исходников [mangoapp.cpp](file:///root/gamescope/src/mangoapp.cpp))

```c
struct mangoapp_msg_v1 {
    struct mangoapp_msg_header hdr;  // long msg_type + uint32_t version
    uint32_t pid;
    uint64_t app_frametime_ns;       // ← ВТОРОЕ поле
    uint8_t fsrUpscale;
    uint8_t fsrSharpness;
    uint64_t visible_frametime_ns;   // ← ЧЕТВЁРТОЕ поле
    uint64_t latency_ns;
    uint32_t outputWidth;
    uint32_t outputHeight;
    uint16_t displayRefresh;         // ← НОВОЕ
    bool bAppWantsHDR : 1;          // ← НОВОЕ
    bool bSteamFocused : 1;         // ← НОВОЕ
    char engineName[40];            // ← НОВОЕ
} __attribute__((packed));
```

### MangoHud 0.8.2 (наш, из исходников [mangoapp_proto.h](file:///root/MangoHud/src/app/mangoapp_proto.h))

```c
struct mangoapp_msg_v1 {
    struct mangoapp_msg_header hdr;
    uint32_t pid;
    uint64_t visible_frametime_ns;   // ← ВТОРОЕ поле (другой порядок!)
    uint8_t fsrUpscale;
    uint8_t fsrSharpness;
    uint64_t app_frametime_ns;       // ← ЧЕТВЁРТОЕ поле (другой порядок!)
    uint64_t latency_ns;
    uint32_t outputWidth;
    uint32_t outputHeight;
    // Нет displayRefresh, bAppWantsHDR, bSteamFocused, engineName
} __attribute__((packed));
```

> [!WARNING]
> Порядок `visible_frametime_ns` и `app_frametime_ns` **перепутан** между версиями.
> На реальном Deck Gamescope 3.16.14.5 + MangoHud 0.8.1-r103 — struct совпадает.
> У нас Gamescope 3.16.20 изменил порядок, MangoHud 0.8.2 не обновил.

---

## 8. Обнаруженные причины неработоспособности

### Причина 1: MangoApp crash — мусор в SysV IPC

MangoApp падает с `"Unsupported mangoapp struct version: 0"` → SIGABRT.
SysV очередь (key 0xffffffff) сохраняет сообщения между сессиями.
При crash остаточные/мусорные сообщения приводят к получению `version=0`.

**Статус**: обходится очисткой `ipcrm -q` перед запуском.

### Причина 2: MangoHud конфиг readonly

`chmod 444` на `/tmp/mangohud-gamescope.conf` блокирует Steam от записи `preset=N`.
На реальном Deck конфиг **644** — Steam свободно дописывает настройки.
Без `preset` MangoApp не инициализирует overlay.

**Статус**: нужно убрать `chmod 444` из скрипта.

### Причина 3: Struct mismatch Gamescope ↔ MangoHud

Gamescope 3.16.20 изменил порядок полей в `mangoapp_msg_v1`.
MangoHud 0.8.2 (из Fedora repos) не синхронизирован с этой версией.
MangoHud на Steam Deck = 0.8.1-r103 (Valve custom build, синхронизированный).

**Статус**: требуется пересборка MangoHud из правильной ветки или синхронизация struct.

---

## 9. Рекомендации

1. **Убрать `chmod 444`** — конфиг должен быть записываемым (644)
2. **Добавить `ipcrm`** cleanup в `sunshine-prep-gamescope.sh`
3. **Пересобрать MangoHud** из ветки, совместимой с Gamescope 3.16.20,
   или использовать SteamOS-версию MangoHud 0.8.1-r103
4. **Добавить `preset=2`** в начальный конфиг MangoHud
