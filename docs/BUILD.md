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
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
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

**CMake ≥ 3.25** (ориентир; см. upstream docs), **Ninja**, **Node.js / npm**. Опции — [`options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).

### 4.1 Вложенные submodules

```bash
cd subprojects/sunshine
git submodule update --init --recursive
```

### 4.2 Компилятор (рекомендации upstream)

| Компилятор | Версия |
|------------|--------|
| GCC | 14+ |
| Clang | 17+ |

### 4.3 Зависимости Linux

Полные списки для Debian/Ubuntu/Fedora/Arch — в [`scripts/linux_build.sh`](../subprojects/sunshine/scripts/linux_build.sh).

Кратко: cmake, ninja, git, gcc/g++, curl, miniupnpc, openssl, opus, pulse/pipewire dev, wayland/X11/drm, Vulkan + glslang/glslc, Python jinja2/setuptools (glad), npm, при необходимости libva, appstream для упаковки.

Официальный «всё в одном» (осторожно: может тянуть CUDA runfile — читайте скрипт):

```bash
cd subprojects/sunshine
./scripts/linux_build.sh --help
# ./scripts/linux_build.sh --step=all
```

### 4.4 CUDA (NVIDIA)

Нужна для CUDA-специфичных путей (в т.ч. NVFBC и связанное). Совместимость CUDA ↔ GCC — [CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/index.html). Рекомендация upstream — порядка **CUDA 12.9** (проверяйте актуальность).

```bash
cmake -B build -G Ninja -S . \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_BUILD_TYPE=Release
```

По умолчанию **`CUDA_FAIL_ON_MISSING=ON`**. Без CUDA: **`-DSUNSHINE_ENABLE_CUDA=OFF`** (и при необходимости **`-DCUDA_FAIL_ON_MISSING=OFF`**).

### 4.5 Ручная сборка

```bash
cd subprojects/sunshine
git submodule update --init --recursive
cmake -B build -G Ninja -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_DOCS=OFF \
  -DBUILD_WERROR=OFF
ninja -C build
```

Полезные флаги: `SUNSHINE_ENABLE_WAYLAND`, `SUNSHINE_ENABLE_X11`, `SUNSHINE_ENABLE_DRM`, `SUNSHINE_ENABLE_CUDA`, `SUNSHINE_ENABLE_VAAPI`, `SUNSHINE_ENABLE_VULKAN`, `BUILD_TESTS`, `NPM_OFFLINE`.

### 4.6 KMS и capabilities

```bash
sudo setcap cap_sys_admin,cap_sys_nice+p build/sunshine
```

### 4.7 Упаковка

```bash
cpack -G DEB --config ./build/CPackConfig.cmake
cpack -G RPM --config ./build/CPackConfig.cmake
```

---

## 5. Рекомендуемый порядок

1. `git submodule update --init --recursive` в корне.
2. Собрать **CDH** — проверка wlroots и тулчейна.
3. **Gamescope** — если нужен Deck-режим из исходников.
4. **Sunshine** — самый тяжёлый шаг (CMake, npm, возможно CUDA).

Gamescope и Sunshine можно не собирать из submodule, если устраивают пакеты дистрибутива.

---

## 6. Типичные сбои (сводка)

| Симптом | Действие |
|---------|----------|
| Нет файлов в Sunshine `third-party/` | `git submodule update --init --recursive` в `subprojects/sunshine` |
| Sunshine / CUDA | CUDA + `CMAKE_CUDA_COMPILER` или `-DSUNSHINE_ENABLE_CUDA=OFF` |
| Sunshine / npm | `node`/`npm`, сеть при первой сборке |
| Gamescope / subprojects | `git submodule update --init --recursive` в `subprojects/gamescope` |
| CDH / wlroots | `git submodule update --init subprojects/wlroots` |

---

## 7. Ссылки

- [Sunshine — Building](https://github.com/LizardByte/Sunshine/blob/master/docs/building.md)
- [Sunshine — options.cmake](https://github.com/LizardByte/Sunshine/blob/master/cmake/prep/options.cmake)
- [Gamescope README](https://github.com/ValveSoftware/gamescope/blob/master/README.md)
