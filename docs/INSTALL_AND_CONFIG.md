# Установка и настройка: cloud-desktop-host

Стек: **PVE хост → LXC контейнер (Fedora) → CDH → Sunshine → Moonlight**

Документ разделён на две части:
- **[Часть I](#часть-i--хост-proxmox-ve)** — хост Proxmox VE: NVIDIA-драйвер, создание LXC, `cgroup2`, маунты устройств.
- **[Часть II](#часть-ii--lxc-контейнер-fedora)** — внутри контейнера: пакеты, сборка CDH, Sunshine, конфиги, скрипты запуска.

Конфигурации взяты из реального окружения (контейнер **120 / fedora07**, GPU **RTX 3090**, драйвер **580.126.09**). Замените номер контейнера и имена устройств под своё железо.

---

## Часть I — Хост (Proxmox VE)

### I.1 Требования к хосту

| Компонент | Требование |
|-----------|------------|
| **GPU** | NVIDIA с поддержкой NVENC (RTX / GTX серии 600+) |
| **Драйвер NVIDIA на хосте** | Совпадать с версией в контейнере (580.126.09) |
| **Ядро PVE** | ≥ 6.x (используется `cgroup2`) |
| **Proxmox VE** | ≥ 8.0 |
| **Приоритет IOMMU / VT-d** | Не требуется для LXC с биндом устройств |

> **Важно:** версия драйвера NVIDIA **на хосте** и **в контейнере** должны быть **одинаковыми**. Если они расходятся — NVIDIA-устройства в контейнере будут недоступны.

### I.2 Установка NVIDIA-драйвера на хост PVE

На хосте PVE Debian-based. Ставим драйвер без X11:

```bash
# Добавить non-free репозиторий (если не добавлен)
sed -i 's/^deb /deb [arch=amd64] /' /etc/apt/sources.list
echo "deb http://deb.debian.org/debian $(lsb_release -cs) main contrib non-free non-free-firmware" \
  >> /etc/apt/sources.list.d/non-free.list
apt-get update

# Установить драйвер (без X11, только kernel module)
apt-get install -y nvidia-driver nvidia-smi

# Проверить
nvidia-smi
```

Или через официальный runfile:

```bash
# Скачать с developer.nvidia.com → «Linux 64-bit» → нужная версия
chmod +x NVIDIA-Linux-x86_64-580.126.09.run
./NVIDIA-Linux-x86_64-580.126.09.run --no-opengl-files --no-libglx-indirect
```

После установки:

```bash
# Загрузить модули
modprobe nvidia nvidia_uvm nvidia_modeset

# Проверить cgroup2 устройства:
ls -la /dev/nvidia* /dev/nvidia-caps/ /dev/dri/
```

Фиксируем номера `major:minor` — они нужны для `lxc.cgroup2.devices.allow`:

```bash
ls -la /dev/nvidia0 /dev/nvidiactl /dev/nvidia-modeset /dev/nvidia-uvm \
        /dev/nvidia-uvm-tools /dev/dri/card2 /dev/dri/renderD128 \
        /dev/input /dev/snd /dev/uinput /dev/nvidia-caps
```

Пример (RTX 3090, хост из этого окружения):

```
crw-rw-rw- 1 root video  195,   0  /dev/nvidia0
crw-rw-rw- 1 root video  195, 255  /dev/nvidiactl
crw-rw-rw- 1 root video  195, 254  /dev/nvidia-modeset
crw-rw-rw- 1 root video  235,   0  /dev/nvidia-uvm
crw-rw-rw- 1 root video  235,   1  /dev/nvidia-uvm-tools
crw-rw-rw- 1 root video  226,   2  /dev/dri/card2
crw-rw-rw- 1 root video  226, 128  /dev/dri/renderD128
```

### I.3 Создание LXC контейнера

В веб-интерфейсе Proxmox VE: **Create CT** → Fedora template, или через CLI:

```bash
pct create 120 /var/lib/vz/template/cache/fedora-42-default_*.tar.zst \
  --ostype fedora \
  --arch amd64 \
  --hostname fedora07 \
  --cores 16 \
  --memory 24000 \
  --swap 1024 \
  --rootfs local-zfs:64 \
  --net0 name=eth0,bridge=vmbr0,ip=dhcp,ip6=dhcp,type=veth \
  --features fuse=1,nesting=1
```

### I.4 Конфигурационный файл контейнера

Полный конфиг — **`/etc/pve/lxc/120.conf`** (реальный конфиг этого окружения):

```ini
arch: amd64
cores: 16
features: fuse=1,nesting=1
hostname: fedora07
memory: 24000
mp0: /bindfs/101,mp=/nas
net0: name=eth0,bridge=vmbr0,hwaddr=BC:24:11:45:06:42,ip=dhcp,ip6=dhcp,type=veth
ostype: fedora
rootfs: local-zfs:subvol-120-disk-2,size=64G
swap: 1024

# ── NVIDIA GPU ────────────────────────────────────────────────────
# major 195 = nvidia0 / nvidiactl / nvidia-modeset
lxc.cgroup2.devices.allow: c 195:* rwm
# major 235 = nvidia-uvm / nvidia-uvm-tools
lxc.cgroup2.devices.allow: c 235:* rwm
# major 509 = nvidia-caps (cap1, cap2)
lxc.cgroup2.devices.allow: c 509:* rwm
# major 508 = nvidia-uvm-tools (может отличаться)
lxc.cgroup2.devices.allow: c 508:* rwm

# major 226 = /dev/dri (DRM — нужен для GLES/EGL через Mesa)
lxc.cgroup2.devices.allow: c 226:* rwm

# ── Ввод ─────────────────────────────────────────────────────────
# major 13 = /dev/input/* (libinput)
lxc.cgroup2.devices.allow: c 13:* rwm
# major 10, minor 223 = /dev/uinput (виртуальные устройства Sunshine)
lxc.cgroup2.devices.allow: c 10:223 rwm

# ── Звук ─────────────────────────────────────────────────────────
# major 116 = /dev/snd/* (ALSA)
lxc.cgroup2.devices.allow: c 116:* rwm

# ── Маунты устройств в контейнер ─────────────────────────────────
lxc.mount.entry: /dev/nvidia0           dev/nvidia0           none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl         dev/nvidiactl         none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset    dev/nvidia-modeset    none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm        dev/nvidia-uvm        none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools  dev/nvidia-uvm-tools  none bind,optional,create=file
lxc.mount.entry: /dev/dri/card2         dev/dri/card2         none bind,optional,create=file
lxc.mount.entry: /dev/dri/renderD128    dev/dri/renderD128    none bind,optional,create=file
lxc.mount.entry: /dev/input             dev/input             none bind,optional,create=dir
lxc.mount.entry: /dev/snd               dev/snd               none bind,optional,create=dir
lxc.mount.entry: tmpfs dev/shm tmpfs rw,nosuid,nodev,mode=1777,size=4G,create=dir 0 0
lxc.mount.entry: /dev/uinput            dev/uinput            none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-caps       dev/nvidia-caps       none bind,optional,create=dir

# ── Безопасность / sys ────────────────────────────────────────────
# unconfined — без AppArmor ограничений (нужно для Wayland/libinput в LXC)
lxc.apparmor.profile: unconfined
# sys:rw — Wayland-compositor и wlroots требуют запись в /sys
lxc.mount.auto: sys:rw

# ── Capabilities (обязательно для KWin) ───────────────────────────
# lxc-pve 7.0+ по умолчанию вырезает sys_nice из capability bounding set
# контейнера (в /usr/share/lxc/config/fedora.common.conf). Но бинарник
# kwin_wayland несёт file capability cap_sys_nice=ep (с effective-битом, её
# ставит сам RPM пакета kwin). Без sys_nice в bounding set ядро отказывает
# в exec с EPERM → KWin не стартует → Desktop-режим отдаёт только цветные
# переливы (заглушка CDH при отсутствии desktop_surface).
# Решение: сбросить дефолтный drop-лист и передать его БЕЗ sys_nice.
lxc.cap.drop:
lxc.cap.drop: mac_admin mac_override setfcap sys_module sys_pacct sys_rawio sys_time
```

> **Примечание:** `/dev/dri/card2` — конкретная карта на этом хосте (RTX 3090). У вас может быть `/dev/dri/card0` или `card1`. Определите через `ls /dev/dri/` и сопоставьте с `nvidia-smi` (номер GPU = 0).

Применить изменения в конфиге:

```bash
pct reboot 120
```

> **Важно (capability `sys_nice`):** блок `lxc.cap.drop` выше — не косметика. Capability bounding set применяется **только при старте контейнера**, поэтому после правки нужен именно `pct stop 120 && pct start 120` (или `pct reboot 120`), а не «на лету». Без этого override после `lxc-pve 7.0+` `kwin_wayland` не запускается (EPERM), и Desktop-режим показывает только цветные переливы. Проверка после рестарта:
>
> ```bash
> # sys_nice должен присутствовать в bounding set:
> pct exec 120 -- bash -lc 'B=$(awk "/CapBnd/{print \$2}" /proc/1/status); capsh --decode=0x$B | tr "," "\n" | grep sys_nice'
> # kwin_wayland должен исполняться (печатать версию, а не "Operation not permitted"):
> pct exec 120 -- runuser -u user -- kwin_wayland --version
> ```
>
> Почему так: это привилегированный LXC, и фикс живёт в host-конфиге `120.conf`, которого `dnf` внутри контейнера не касается — значит он **переживает обновления** kwin и пакетов без всяких хуков. Править метку на бинарнике (`setcap -r`) бесполезно: её вернёт первый же `dnf upgrade kwin`.

### I.5 Проброс /dev/input и uinput

Sunshine создаёт виртуальные устройства (геймпад, мышь) через `/dev/uinput`. libinput в CDH читает реальный ввод через `/dev/input/*`. Оба нужны.

На хосте убедитесь, что модуль `uinput` загружен:

```bash
modprobe uinput
# Сделать автозагрузку:
echo uinput >> /etc/modules-load.d/uinput.conf
```

---

## Часть II — LXC контейнер (Fedora)

Все команды ниже выполняются **внутри контейнера** (через `pct enter 120` или `pct exec 120 -- bash`).

### II.1 Базовые пакеты

```bash
dnf update -y
dnf install -y \
  # Сборка CDH
  meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
  wayland-devel wayland-protocols-devel mesa-libGLES-devel \
  libinput-devel systemd-devel libdrm-devel mesa-libgbm-devel \
  libxkbcommon-devel pixman-devel \
  # Среда
  dbus-daemon dbus-tools \
  pipewire wireplumber pipewire-pulseaudio pipewire-utils \
  xorg-x11-server-Xwayland \
  # KDE Plasma
  kwin plasma-desktop \
  # Утилиты
  busctl git wget curl
```

### II.2 NVIDIA-драйвер в контейнере

> **Важно:** версия должна совпадать с версией на хосте PVE (в нашем случае **580.126.09**).

Устанавливаем без ядерных модулей (они уже в хосте):

```bash
# Официальный runfile с флагом --no-kernel-module
wget https://download.nvidia.com/XFree86/Linux-x86_64/580.126.09/NVIDIA-Linux-x86_64-580.126.09.run
chmod +x NVIDIA-Linux-x86_64-580.126.09.run
./NVIDIA-Linux-x86_64-580.126.09.run \
  --no-kernel-module \
  --no-opengl-files \
  --no-libglx-indirect \
  --install-compat32-libs \
  -s

# Проверить
nvidia-smi
```

Или через dnf (если rpm-fusion настроен и версия совпадает):

```bash
dnf install -y akmod-nvidia xorg-x11-drv-nvidia-cuda
```

Проверка после установки:

```bash
nvidia-smi
ls /dev/nvidia*
# Ожидаемый вывод:
# /dev/nvidia0  /dev/nvidiactl  /dev/nvidia-modeset  /dev/nvidia-uvm  /dev/nvidia-uvm-tools
```

### II.3 Создание пользователя

CDH и стек Sunshine запускаются **от непривилегированного пользователя** `user`.

```bash
useradd -m -G input,video,render,audio user
# Если нужен sudo:
usermod -aG wheel user
echo "%wheel ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/user
```

### II.4 Клонирование и сборка CDH

```bash
su - user
cd /home/user

git clone --recurse-submodules https://github.com/wolfram0108/cloud-desktop-host.git
cd cloud-desktop-host
git submodule update --init --recursive

meson setup build
ninja -C build

# Проверить
./build/cloud-desktop-host --help
```

Результат: `/home/user/cloud-desktop-host/build/cloud-desktop-host`

### II.5 Сборка Gamescope (для Steam Deck Mode)

```bash
cd /home/user/cloud-desktop-host/subprojects/gamescope
git submodule update --init --recursive

# Зависимости Gamescope
sudo dnf install -y vulkan-loader-devel libX11-devel libxcb-devel \
  xorg-x11-proto-devel pipewire-devel

meson setup build
ninja -C build

# Проверить
./build/src/gamescope --version
```

Путь к бинарнику используется в prep-скрипте:
`/home/user/cloud-desktop-host/subprojects/gamescope/build/src/gamescope`

(задаётся в переменной `GAMESCOPE_BIN` в [`scripts/sunshine-prep-gamescope.sh`](../scripts/sunshine-prep-gamescope.sh))

### II.6 Установка Sunshine

Рекомендуется установить из **RPM** (собранный или официальный релиз).

Скачать последний RPM из [releases LizardByte/Sunshine](https://github.com/LizardByte/Sunshine/releases):

```bash
# Пример (замените URL на актуальный)
wget https://github.com/LizardByte/Sunshine/releases/download/v2026.403.124357/sunshine-fedora-42.rpm
sudo dnf install -y ./sunshine-*.rpm
```

Или собрать из submodule — см. [docs/BUILD.md](BUILD.md), §4.

Проверить:

```bash
sunshine --version
which sunshine
```

После установки Sunshine создаёт сокет для веб-UI на порту **47990**.  
Если запускается от user, добавить в группу:

```bash
sudo usermod -aG input video user
```

### II.7 Конфигурация Sunshine

#### II.7.1 Глобальные настройки Sunshine

Конфиг: `~/.config/sunshine/sunshine.conf`

```ini
# Захват через wlr_screencopy (Wayland — основной путь)
capture = wlr

# Кодировщик: NVENC (NVIDIA). Sunshine выберет автоматически при наличии GPU.
encoder = nvenc

# Логи
log_level = info

# Сеть
port = 47989

# Включить UPnP если нужно
upnp = off

# Путь к apps.json
file_apps = /home/user/cloud-desktop-host/configs/sunshine/apps.json
```

Или через веб-интерфейс `https://localhost:47990`.

#### II.7.2 Профили приложений

Файл [`configs/sunshine/apps.json`](../configs/sunshine/apps.json) — **два профиля**:

```json
{
  "env": {},
  "apps": [
    {
      "name": "Desktop",
      "image-path": "",
      "prep-cmd": [
        {
          "do":   "/home/user/cloud-desktop-host/scripts/sunshine-prep-desktop.sh",
          "undo": "/home/user/cloud-desktop-host/scripts/sunshine-undo-desktop.sh"
        }
      ]
    },
    {
      "name": "Steam Deck Mode",
      "image-path": "",
      "prep-cmd": [
        {
          "do":   "/home/user/cloud-desktop-host/scripts/sunshine-prep-gamescope.sh",
          "undo": "/home/user/cloud-desktop-host/scripts/sunshine-undo-gamescope.sh"
        }
      ]
    }
  ]
}
```

Скопировать в конфиг-каталог Sunshine:

```bash
mkdir -p ~/.config/sunshine
cp /home/user/cloud-desktop-host/configs/sunshine/apps.json ~/.config/sunshine/apps.json
```

#### II.7.3 Права на скрипты

```bash
chmod +x /home/user/cloud-desktop-host/scripts/*.sh
```

---

### II.8 Запуск стека

#### II.8.1 Desktop Mode (Plasma + KWin)

Основной скрипт: [`scripts/run.sh`](../scripts/run.sh)  
Без логов: `./scripts/run.sh --no-log` (KWin и Plasma поднимает prep-скрипт при подключении)

```bash
su - user
cd /home/user/cloud-desktop-host
./scripts/run.sh
```

`run.sh` запускает в порядке:

```
1. D-Bus session
2. PipeWire → WirePlumber → PipeWire-Pulse
3. kactivitymanagerd (offscreen)
4. cloud-desktop-host      → сокет wayland-cd
5. KWin                    → сокет wayland-0 + Xwayland
6. dbus-update-activation-environment
7. kded6
8. plasmashell + polkit
9. Sunshine (WAYLAND_DISPLAY=wayland-cd)
```

Логи пишутся в `/tmp/cdhost-logs/<время>/` (последние 5 запусков, ссылка `latest`).

#### II.8.2 Steam GamepadUI Mode

Скрипт: [`scripts/run.sh --steam`](../scripts/run.sh)

```bash
./scripts/run.sh --steam
```

Запускает CDH с `--no-auto-lock`, Xwayland fullscreen на `:0`, Steam с `-gamepadui`.

---

### II.9 Переключение режимов через Sunshine

Когда Moonlight **подключается**, Sunshine автоматически вызывает prep-скрипт выбранного приложения, который:

1. Вызывает D-Bus **`SetOutputMode(width, height, fps)`** → CDH адаптирует headless output.
2. Запускает нужный стек (KWin+Plasma или Gamescope+Steam).

Когда Moonlight **отключается**, выполняется undo-скрипт.

#### Desktop — prep/undo

| Событие | Скрипт | Действие |
|---------|--------|----------|
| Подключение | [`sunshine-prep-desktop.sh`](../scripts/sunshine-prep-desktop.sh) | Cleanup Gamescope → `SetOutputMode` → KWin (если нет) → Plasma stack |
| Отключение | [`sunshine-undo-desktop.sh`](../scripts/sunshine-undo-desktop.sh) | Kill plasmashell, kded6, polkit |

#### Steam Deck Mode — prep/undo

| Событие | Скрипт | Действие |
|---------|--------|----------|
| Подключение | [`sunshine-prep-gamescope.sh`](../scripts/sunshine-prep-gamescope.sh) | Cleanup всего → `SetOutputMode` → Gamescope nested + Steam `-steamos3` |
| Отключение | [`sunshine-undo-gamescope.sh`](../scripts/sunshine-undo-gamescope.sh) | Kill Steam, Gamescope, Xwayland, lock-файлы |

#### Ручная смена разрешения через D-Bus

```bash
# Например: 2560×1440 @ 144 fps
busctl --user call \
  org.gamescope.Input \
  /org/gamescope/Input \
  org.gamescope.InputDeviceManager \
  SetOutputMode uuu \
  2560 1440 144
```

---

### II.10 Настройка мыши (D-Bus / gamescope-input.conf)

CDH публикует интерфейс **`org.gamescope.Input`** (совместим с **KCM Cloud Mouse**).

Страница «Мышь» в KDE не видит устройства CDH (KWin вложенный). GUI — **System Settings → Input Devices → Cloud Mouse**: `pve/install.sh` ставит RPM из релизов [kcm-cloud-mouse](https://github.com/chiririll/kcm-cloud-mouse) (`CLOUD_MOUSE_RPM=none` — пропустить).

#### Настройки через D-Bus вручную

```bash
# Просмотр устройств
busctl --user get-property \
  org.gamescope.Input /org/gamescope/Input \
  org.gamescope.InputDeviceManager devicesSysNames

# Настройка scrollFactor для устройства (замените <sysname> на имя из списка выше):
busctl --user set-property \
  org.gamescope.Input \
  /org/gamescope/Input/Device/<sysname> \
  org.gamescope.InputDevice scrollFactor d 8.0
```

#### Файл персистентных настроек

`~/.config/gamescope-input.conf` — INI, секции по `sysname` устройства:

```ini
[event3]
scrollFactor=8.0
naturalScroll=false
pointerAcceleration=0.0
accelProfile=adaptive   # или flat
```

---

### II.11 autostart (systemd user-сервис)

Запуск стека при старте контейнера от пользователя `user`:

```ini
# /home/user/.config/systemd/user/cloud-desktop.service
[Unit]
Description=cloud-desktop-host stack
After=default.target

[Service]
Type=simple
WorkingDirectory=/home/user/cloud-desktop-host
ExecStart=/home/user/cloud-desktop-host/scripts/run.sh
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=default.target
```

Включить:

```bash
loginctl enable-linger user
systemctl --user enable cloud-desktop.service
systemctl --user start cloud-desktop.service
systemctl --user status cloud-desktop.service
```

---

### II.12 Moonlight на клиенте

1. Скачать [Moonlight](https://moonlight-stream.org/).
2. Добавить хост — IP контейнера (не хоста PVE) или IP хоста (порт 47989 Sunshine слушает в контейнере, а NAT/firewall должен пробрасывать).
3. Выбрать приложение: **Desktop** или **Steam Deck Mode**.
4. Задать разрешение и FPS (до 144 Hz). Sunshine передаст их в prep-скрипт → `SetOutputMode`.
5. Включить аппаратный декод на стороне клиента (NVDEC / VAAPI / D3D11VA).

---

### II.13 Диагностика

| Что проверять | Где смотреть |
|---------------|-------------|
| Лог CDH | `/tmp/cdhost-logs/latest/compositor.log` |
| Prep Desktop | `/tmp/cdhost-logs/latest/prep-desktop.log` |
| Prep Gamescope | `/tmp/cdhost-logs/latest/prep-gamescope.log` |
| Gamescope | `/tmp/cdhost-logs/latest/gamescope.log` |
| Sunshine | `/tmp/cdhost-logs/latest/sunshine.log` |
| KWin | `/tmp/cdhost-logs/latest/kwin.log` |
| PipeWire | `/tmp/cdhost-logs/latest/pipewire.log` |
| HUD overlay | запустить CDH с `--hud` → оверлей FPS/commit rate в стриме |
| Verbose wlroots | запустить CDH с `--debug` |

Быстрая проверка, что CDH поднял сокет:

```bash
ls -la /run/user/$(id -u)/wayland-cd
```

Проверка D-Bus:

```bash
busctl --user list | grep gamescope
```

---

### II.14 Типичные проблемы

| Симптом | Причина | Решение |
|---------|---------|---------|
| `FAIL: no wayland-cd` | CDH не запустился | Проверить `/tmp/cdh.log`, права на устройства |
| `busctl: service not found` | CDH не запустил D-Bus сервис | CDH должен быть запущен перед prep-скриптом |
| Чёрный экран в Moonlight | KWin не подключился к CDH | `WAYLAND_DISPLAY=wayland-cd` в env KWin |
| Desktop: цветные переливы (RGB-анимация) вместо рабочего стола | `kwin_wayland` не стартует (EPERM): метка `cap_sys_nice=ep`, а `sys_nice` вырезан из bounding set контейнера (дефолт `lxc-pve 7.0+`). В `/tmp/cdhost-logs/latest/prep-desktop.log` видно `DISPLAY=N/A` и падение Plasma | Вернуть `sys_nice` в bounding set — override `lxc.cap.drop` в `/etc/pve/lxc/120.conf` (см. §I.4), затем `pct stop 120 && pct start 120` |
| Нет звука | PipeWire не запустился или `/dev/snd` не примаплен | Проверить `lxc.mount.entry: /dev/snd` и `lxc.cgroup2.devices.allow: c 116:*` |
| NVENC недоступен | Версии драйвера хоста/контейнера различаются | Установить одинаковые версии; проверить `nvidia-smi` в контейнере |
| Gamescope не видит Wayland | `WAYLAND_DISPLAY` не задан | Задать `WAYLAND_DISPLAY=wayland-cd` перед запуском Gamescope |
| MangoApp не отображается | GLFW выбирает Wayland backend | Задать `GLFW_PLATFORM=x11` (уже в `sunshine-prep-gamescope.sh`) |
| Мышь не захватывается | `uinput` не доступен | `lxc.mount.entry: /dev/uinput` + `lxc.cgroup2.devices.allow: c 10:223 rwm` |
