# Сборка: cloud-desktop-host, субмодули и утилиты

Один документ: **композитор CDH** (вместе с wlroots), **Gamescope**, **Sunshine**, вспомогательный **`gamescope-focus-daemon`**.

Если у вас есть локальный черновик с другого ПК (например `D:\Download\BUILD.md`), сверьте с ним дистрибутив-специфичные шаги — здесь обобщённая версия по upstream.

**Первоисточники:**

- Sunshine: [документация LizardByte](https://docs.lizardbyte.dev/projects/sunshine/latest/), в submodule — [`subprojects/sunshine/docs/building.md`](../subprojects/sunshine/docs/building.md), [`scripts/linux_build.sh`](../subprojects/sunshine/scripts/linux_build.sh), [`cmake/prep/options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).
- Gamescope: [`subprojects/gamescope/README.md`](../subprojects/gamescope/README.md).
- CDH + wlroots: корневой [`meson.build`](../meson.build).

> **Важно:** у **Sunshine** много **вложенных** git submodules (`third-party/*` и др.). Без `git submodule update --init --recursive` внутри `subprojects/sunshine` CMake часто падает или не хватает исходников.

---

## 1. Клонирование и обновление submodules

```bash
git clone --recurse-submodules https://github.com/wolfram0108/cloud-desktop-host.git
cd cloud-desktop-host
```

Если репозиторий уже клонирован без submodules:

```bash
git submodule update --init --recursive
```

Перед сборкой **Sunshine**:

```bash
git submodule update --init --recursive subprojects/sunshine
```

Проверка: `git submodule status`.

| Каталог | Upstream | Версия (ориентир) |
|---------|----------|-------------------|
| `subprojects/wlroots` | freedesktop.org | **0.18.3** |
| `subprojects/gamescope` | ValveSoftware | **3.16.14.5** |
| `subprojects/sunshine` | LizardByte | **v2026.403.124357** (см. `git submodule status`) |

Подробнее про submodule-модель — [SUBPROJECTS.md](SUBPROJECTS.md).

---

## 2. cloud-desktop-host + wlroots

**wlroots** для CDH **не** собирается отдельным шагом: Meson подключает его как `subproject('wlroots')`.

### 2.1 Зависимости

Соответствуют [`meson.build`](../meson.build):

| Зависимость | Назначение |
|-------------|------------|
| **meson** (≥ 0.59 для wlroots), **ninja** | Система сборки |
| **gcc** / **clang**, **C11** и **C++17** | Компиляторы |
| **pkg-config** | Поиск библиотек |
| **wlroots 0.18.3** | Submodule `subprojects/wlroots` |
| **wayland-server** | Сервер Wayland |
| **wayland-protocols** (≥ 1.35) | XML-протоколы |
| **libgles2** (GLESv2) | Рендерер wlroots |
| **libinput**, **libudev** | Ввод |
| **libsystemd** | sd-bus (D-Bus в CDH) |
| **libdrm**, **GBM** | типично для allocator/renderer |
| **libxkbcommon**, **pixman** | через стек wlroots / HUD |

Пример **Fedora**:

```bash
sudo dnf install meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
  wayland-devel wayland-protocols-devel mesa-libGLES-devel \
  libinput-devel systemd-devel libdrm-devel mesa-libgbm-devel \
  libxkbcommon-devel pixman-devel
```

На Debian/Ubuntu имена пакетов другие (`libwayland-dev` и т.д.).

### 2.2 Сборка CDH

Из корня репозитория:

```bash
meson setup build
ninja -C build
```

Результат: `build/cloud-desktop-host`.

Пересборка: `ninja -C build`.

Чистая пересборка:

```bash
rm -rf build
meson setup build
ninja -C build
```

Установка в префикс (опционально):

```bash
meson setup build --prefix=/usr/local
ninja -C build
sudo ninja -C build install
```

### 2.3 Утилита `gamescope-focus-daemon`

Исходник: [`tools/gamescope-focus-daemon.c`](../tools/gamescope-focus-daemon.c).

```bash
gcc -O2 -o gamescope-focus-daemon tools/gamescope-focus-daemon.c $(pkg-config --cflags --libs x11)
```

Флаги зависят от окружения; при желании оформите `meson.build` в `tools/`.

### 2.4 Типичные ошибки (CDH)

- **`meson: command not found`** — установите meson и ninja.
- **Не найден wlroots** — `git submodule update --init subprojects/wlroots`.
- **Нет wayland-protocols** — пакет с XML (не путать с `wayland-server`).
- **GLES/renderer** — Mesa и доступ к `/dev/dri` (в контейнере — проброс GPU).

---

## 3. Gamescope (Valve)

Отдельный бинарник для режима **Steam Deck** (nested Gamescope). **Meson + Ninja**. Нужен `git submodule update --init --recursive` **внутри** `subprojects/gamescope`.

Для продакшена часто проще поставить **пакет дистрибутива**, а submodule держать для **версии и патчей**.

### 3.1 Зависимости (ориентир)

По [`meson.build`](../subprojects/gamescope/meson.build) и README: Vulkan, X11, Wayland, Pipewire (по опциям), C++20, glm/stb как subprojects Gamescope. Для NVIDIA nested — см. README Gamescope (`nvidia-drm.modeset=1`).

Пример **Fedora**:

```bash
sudo dnf install meson ninja-build gcc gcc-c++ \
  libX11-devel wayland-devel vulkan-loader-devel \
  libdrm-devel mesa-libGL-devel pipewire-devel \
  xorg-x11-proto-devel libxcb-devel
```

### 3.2 Сборка

```bash
cd subprojects/gamescope
git submodule update --init --recursive
meson setup build
ninja -C build
# build/gamescope
```

Установка: `meson install -C build --skip-subprojects`.

Не отключайте `force_fallback_for` в Gamescope без понимания — см. комментарий в их `meson.build`.

---

## 4. Sunshine (LizardByte)

**CMake ≥ 3.25**, **Ninja**, **Node.js / npm**, **CUDA Toolkit**. Опции сборки — [`options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).

> **Важно для LXC:** стандартный RPM устанавливает `cap_sys_admin+p` через `setcap`. В LXC это **ломает** сетевой стек Sunshine (ENet) — Moonlight не может подключиться. Перед упаковкой нужен **патч postinst** (см. [§4.5](#45-патч-postinst-обязательно-для-lxc)).

### 4.1 Зависимости (Fedora)

```bash
# Базовые зависимости CDH уже установлены (§2.1).
# Дополнительно для Sunshine:
sudo dnf install -y \
  cmake ninja-build gcc gcc-c++ git \
  glib2-devel pipewire-devel \
  libnotify-devel libayatana-appindicator-gtk3-devel \
  npm doxygen graphviz \
  opus-devel pulseaudio-libs-devel \
  libstdc++-static rpm-build \
  openssl-devel libcurl-devel miniupnpc-devel \
  libevdev-devel libva-devel \
  boost-devel numactl-devel \
  libX11-devel libxcb-devel libXfixes-devel libXrandr-devel libXtst-devel \
  wayland-devel libdrm-devel mesa-libgbm-devel \
  vulkan-loader-devel glslc \
  python3-jinja2 python3-setuptools \
  appstream desktop-file-utils
```

### 4.2 CUDA Toolkit

Sunshine использует CUDA для захвата через NVFBC и связанного кода. Версия CUDA должна быть совместима с используемым GCC (см. [CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/index.html)).

```bash
# Пример: CUDA 13.0 runfile (замените на нужную версию)
wget https://developer.download.nvidia.com/compute/cuda/13.0.0/local_installers/cuda_13.0.0_${DRIVER}_linux.run
chmod +x cuda_*.run
sudo ./cuda_*.run --silent --toolkit --toolkitpath=/usr/local/cuda-13.0 \
  --no-opengl-libs --no-man-page --no-drm

# Проверить
/usr/local/cuda-13.0/bin/nvcc --version
```

### 4.3 Клонирование

Можно использовать **submodule** из репозитория или клонировать напрямую.

**Вариант A — из submodule:**
```bash
cd /home/user/cloud-desktop-host/subprojects/sunshine
git submodule update --init --recursive
```

**Вариант B — отдельное клонирование (рекомендуется для продакшена):**
```bash
su - user
cd ~
git clone --recurse-submodules https://github.com/LizardByte/Sunshine.git
cd Sunshine
```

### 4.4 CMake и компиляция

```bash
# Добавить CUDA в PATH
export PATH=/usr/local/cuda-13.0/bin:$PATH

cmake -B build -G Ninja -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DSUNSHINE_EXECUTABLE_PATH=/usr/bin/sunshine \
  -DSUNSHINE_ENABLE_CUDA=ON \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc \
  -DSUNSHINE_ENABLE_DRM=ON \
  -DSUNSHINE_ENABLE_WAYLAND=ON \
  -DSUNSHINE_ENABLE_X11=ON \
  -DSUNSHINE_ENABLE_PORTAL=ON \
  -DBUILD_DOCS=OFF

ninja -C build -j$(nproc)
```

Без CUDA (если CUDA недоступна):

```bash
cmake -B build -G Ninja -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX=/usr \
  -DSUNSHINE_EXECUTABLE_PATH=/usr/bin/sunshine \
  -DSUNSHINE_ENABLE_CUDA=OFF \
  -DCUDA_FAIL_ON_MISSING=OFF \
  -DSUNSHINE_ENABLE_DRM=ON \
  -DSUNSHINE_ENABLE_WAYLAND=ON \
  -DSUNSHINE_ENABLE_X11=ON \
  -DSUNSHINE_ENABLE_PORTAL=ON \
  -DBUILD_DOCS=OFF
```

### 4.5 Патч postinst — обязательно для LXC

> [!CAUTION]
> Стандартный RPM после установки запускает `setcap cap_sys_admin+p /usr/bin/sunshine`. В LXC это включает `AT_SECURE=1`, что **полностью ломает** сетевой стек ENet — Moonlight не может установить control stream соединение.

| | С `setcap` (стандартный RPM) | Без `setcap` (наша сборка) |
|-|------------------------------|---------------------------|
| `AT_SECURE` | **1** — процесс в privileged режиме | **0** — нормальный |
| Control stream (Moonlight) | ❌ **Не работает** | ✅ Работает |
| Video stream | ❌ **Не работает** | ✅ Работает |

Патч применяется **до** запуска `cpack`:

```bash
# Закомментировать строки с cap_sys_admin в postinst
sed -i '/cap_sys_admin/s/^/#/' src_assets/linux/misc/postinst

# Добавить заглушку, чтобы if-else в postinst не сломался
sed -i '/^#.*cap_sys_admin+p.*sunshine/a\    true  # cap_sys_admin disabled for LXC' \
  src_assets/linux/misc/postinst

# Убедиться что патч применён:
grep -A2 -B2 'cap_sys_admin' src_assets/linux/misc/postinst
```

Ожидаемый результат после патча — строки с `setcap cap_sys_admin` закомментированы, рядом стоит `true`.

### 4.6 Упаковка и установка RPM

```bash
# Создать RPM (после патча postinst)
cpack -G RPM --config ./build/CPackConfig.cmake

# Установить (от root или через sudo)
exit  # если были под user
sudo dnf install -y /home/user/Sunshine/build/cpack_artifacts/Sunshine.rpm
# или если клонировали в subprojects:
sudo dnf install -y /home/user/cloud-desktop-host/subprojects/sunshine/build/cpack_artifacts/Sunshine.rpm
```

Проверка:

```bash
which sunshine
sunshine --version
```

### 4.7 Справка по флагам сборки

Полный список опций — [`subprojects/sunshine/cmake/prep/options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).

| Флаг CMake | По умолч. | Описание |
|------------|-----------|----------|
| `SUNSHINE_ENABLE_WAYLAND` | ON | Захват через wlr_screencopy — **основной путь для CDH** |
| `SUNSHINE_ENABLE_X11` | ON | X11 захват |
| `SUNSHINE_ENABLE_DRM` | ON | KMS захват |
| `SUNSHINE_ENABLE_CUDA` | ON | CUDA-специфичный код (NVFBC и др.) |
| `SUNSHINE_ENABLE_VAAPI` | ON | VA-API (Intel/AMD) |
| `SUNSHINE_ENABLE_VULKAN` | ON | Vulkan video encoding |
| `SUNSHINE_ENABLE_PORTAL` | ON | XDG Desktop Portal |
| `CUDA_FAIL_ON_MISSING` | ON | Ошибка если CUDA не найдена |
| `BUILD_DOCS` | ON | Документация (отключить для быстрой сборки) |
| `BUILD_TESTS` | ON | Тесты |
| `NPM_OFFLINE` | OFF | Офлайн-сборка web UI |

---

## 5. Рекомендуемый порядок

1. `git submodule update --init --recursive` в корне.
2. Собрать **CDH** — проверка wlroots и тулчейна.
3. **Gamescope** — если нужен Deck-режим из исходников.
4. **Sunshine** — самый тяжёлый шаг (CMake, npm, возможно CUDA).

Gamescope и Sunshine можно не собирать из submodule, если устраивают пакеты дистрибутива.

---

## 6. Типичные сбои (сводка)

| Симптом | Причина | Действие |
|---------|---------|----------|
| Moonlight не подключается после установки RPM | `setcap cap_sys_admin+p` → `AT_SECURE=1` → ENet сломан | Пересобрать с патчем postinst (§4.5) |
| Нет файлов в Sunshine `third-party/` | Вложенные submodules не инициализированы | `git submodule update --init --recursive` в каталоге Sunshine |
| Sunshine CMake: `nvcc not found` | CUDA не установлена или путь неверный | Установить CUDA Toolkit, передать `-DCMAKE_CUDA_COMPILER=/usr/local/cuda-13.0/bin/nvcc` |
| Sunshine: `CUDA_FAIL_ON_MISSING` | CUDA не найдена, по умолчанию это ошибка | Добавить `-DSUNSHINE_ENABLE_CUDA=OFF -DCUDA_FAIL_ON_MISSING=OFF` |
| Sunshine / npm ошибки | Node.js/npm не установлены или нет доступа к сети | Установить `npm`, проверить сеть при первой сборке |
| Gamescope / subprojects | Вложенные submodules не инициализированы | `git submodule update --init --recursive` в `subprojects/gamescope` |
| CDH / wlroots не найден | Submodule не инициализирован | `git submodule update --init subprojects/wlroots` |

---

## 7. Ссылки

- [Sunshine — Building](https://github.com/LizardByte/Sunshine/blob/master/docs/building.md)
- [Sunshine — options.cmake](https://github.com/LizardByte/Sunshine/blob/master/cmake/prep/options.cmake)
- [Gamescope README](https://github.com/ValveSoftware/gamescope/blob/master/README.md)
