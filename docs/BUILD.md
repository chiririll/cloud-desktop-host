# Сборка всех субмодулей (CDH, wlroots, Gamescope, Sunshine)

Единый гайд по сборке компонентов из [`subprojects/`](../subprojects/).  
Официальные первоисточники:

- Sunshine: [документация LizardByte](https://docs.lizardbyte.dev/projects/sunshine/latest/), в submodule — [`subprojects/sunshine/docs/building.md`](../subprojects/sunshine/docs/building.md), [`scripts/linux_build.sh`](../subprojects/sunshine/scripts/linux_build.sh), [`cmake/prep/options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).
- Gamescope: [`subprojects/gamescope/README.md`](../subprojects/gamescope/README.md).
- CDH + wlroots: корневой [`meson.build`](../meson.build).

> **Важно:** у **Sunshine** много **вложенных** git submodules (`third-party/*`, Wayland protocols и т.д.). Без `git submodule update --init --recursive` внутри `subprojects/sunshine` конфигурация CMake часто падает или не хватает исходников.

---

## 0. Клонирование и обновление submodules

Из корня **cloud-desktop-host**:

```bash
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
cd cloud-desktop-host
```

Если репозиторий уже есть без вложенных модулей:

```bash
git submodule update --init --recursive
```

Перед сборкой **Sunshine** убедитесь, что подтянуты и его зависимости:

```bash
git submodule update --init --recursive subprojects/sunshine
```

Проверка:

```bash
git submodule status
```

Зафиксированные в этом репозитории версии (см. теги в parent commit):

| Каталог | Upstream | Версия (ориентир) |
|---------|----------|-------------------|
| `subprojects/wlroots` | freedesktop.org | **0.18.3** |
| `subprojects/gamescope` | ValveSoftware | **3.16.14.5** |
| `subprojects/sunshine` | LizardByte | **v2026.403.124357** (календарный тег; при обновлении смените тег осознанно) |

---

## 1. cloud-desktop-host + wlroots

**wlroots** не собирается отдельным шагом для CDH: Meson подтягивает его как `subproject('wlroots')`.

### Зависимости (кратко)

См. полный список в [COMPILATION.md](COMPILATION.md). Минимум: `meson`, `ninja`, компилятор C11/C++17, `wayland-server`, `wayland-protocols`, GLES2, `libinput`, `libudev`, `libsystemd`, `libdrm`, GBM, `libxkbcommon`, `pixman`.

### Сборка

```bash
cd /path/to/cloud-desktop-host
meson setup build
ninja -C build
# результат: build/cloud-desktop-host
```

---

## 2. Gamescope (Valve)

Отдельный бинарник для режима **Steam Deck** (nested Gamescope). Система сборки: **Meson + Ninja**. В upstream зафиксированы fallbacks для `wlroots`, `libliftoff`, `vkroots` — **нужен** `git submodule update --init` **внутри** `subprojects/gamescope`.

### 2.1 Зависимости (типичный набор под Linux)

Зависят от дистрибутива. По [`meson.build`](../subprojects/gamescope/meson.build) и README:

- **Vulkan**: `vulkan-loader`, заголовки Vulkan, драйвер Mesa или NVIDIA (для nested на проприетарном NVIDIA см. README Gamescope: `nvidia-drm.modeset=1`, версия драйвера).
- **X11 / Wayland**: `libx11`, `wayland-client` и dev-пакеты.
- **Дополнительно**: `libpipewire` (часто опционально, см. опции meson), `hwdata`, **glm**, **stb** — обычно как subprojects Gamescope.
- Компилятор с **C++20**.

Пример **Fedora** (имена могут меняться):

```bash
sudo dnf install meson ninja-build gcc gcc-c++ \
  libX11-devel wayland-devel vulkan-loader-devel \
  libdrm-devel mesa-libGL-devel pipewire-devel \
  xorg-x11-proto-devel libxcb-devel
```

### 2.2 Сборка

```bash
cd /path/to/cloud-desktop-host/subprojects/gamescope
git submodule update --init --recursive

meson setup build
ninja -C build
# результат: build/gamescope
```

Установка в префикс (опционально):

```bash
meson install -C build --skip-subprojects
```

Если Meson ругается на `force_fallback_for` — не отключайте перечисленные fallbacks без понимания; для не-пакетной сборки см. комментарий в [`meson.build`](../subprojects/gamescope/meson.build).

---

## 3. Sunshine (LizardByte)

Сборка: **CMake ≥ 3.25** (в `CMakeLists.txt` указан минимум 3.20, в [документации](https://github.com/LizardByte/Sunshine/blob/master/docs/building.md) — **> 3.25** — ориентируйтесь на **3.25+**), генератор **Ninja**, фронтенд веб-UI требует **Node.js / npm**. Много опций в [`options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake).

### 3.1 Вложенные submodules Sunshine

Обязательно:

```bash
cd /path/to/cloud-desktop-host/subprojects/sunshine
git submodule update --init --recursive
```

### 3.2 Компилятор (рекомендации upstream)

| Компилятор | Версия (рекомендация) |
|------------|------------------------|
| GCC        | 14+                    |
| Clang      | 17+                    |

### 3.3 Зависимости Linux

Полный автоматический список для **Debian/Ubuntu/Fedora/Arch** формируется в [`scripts/linux_build.sh`](../subprojects/sunshine/scripts/linux_build.sh) (функции `add_debian_based_deps`, `add_fedora_deps`, `add_arch_deps`).

Кратко по группам:

- **Сборка**: `cmake`, `ninja`, `git`, `gcc`/`g++` нужной версии.
- **Сеть / утилиты**: `curl`, `miniupnpc`, OpenSSL.
- **Аудио/видео**: `opus`, Pulse/PipeWire dev, при необходимости VAAPI (`libva`).
- **Графика**: Wayland, X11, `libdrm`, Vulkan (заголовки, `glslang`/`glslc`), для генерации GL loader — **Python** `jinja2`, `setuptools`.
- **Веб-UI**: `npm` (или NVM на части Ubuntu — см. скрипт).
- **Пакетирование/валидация (для CI-подобного сценария)**: `appstream`, `desktop-file-utils`, `doxygen`/`graphviz` (доки можно отключить).

Пример установки зависимостей **одной командой** (официальный сценарий upstream, из каталога sunshine):

```bash
cd /path/to/cloud-desktop-host/subprojects/sunshine
# Осторожно: скрипт рассчитан на конкретные версии OS из /etc/os-release и может ставить CUDA runfile — читайте код перед запуском на продакшен-хосте.
./scripts/linux_build.sh --help
# типичный полный цикл (deps + cmake + build + package):
# ./scripts/linux_build.sh --step=all
```

Для **ручной** сборки зависимости ставьте пакетным менеджером по спискам из того же `linux_build.sh`.

### 3.4 CUDA Toolkit (NVIDIA)

В [документации Sunshine](https://github.com/LizardByte/Sunshine/blob/master/docs/building.md) указано:

- CUDA нужна для путей захвата/кода, завязанных на **CUDA** (в т.ч. **NVFBC** и связанные компоненты).
- Версия CUDA должна быть **совместима с версией GCC** на дистрибутиве.
- Рекомендация upstream: CUDA **~12.9** (актуальность проверяйте по [CUDA compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/index.html)).

Скрипт `linux_build.sh` на поддерживаемых дистрибутивах может **скачать runfile** NVIDIA и положить toolkit в каталог сборки (см. `install_cuda()`).

При ручном CMake передайте компилятор CUDA, если `nvcc` не в стандартном PATH:

```bash
cmake -B build -G Ninja -S . \
  -DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc \
  -DCMAKE_BUILD_TYPE=Release
```

По умолчанию **`CUDA_FAIL_ON_MISSING=ON`**: если CUDA не найдена, конфигурация может завершиться ошибкой. Варианты:

- Установить CUDA и указать `CMAKE_CUDA_COMPILER`, **или**
- Отключить CUDA-часть: **`-DSUNSHINE_ENABLE_CUDA=OFF`** (и при необходимости **`-DCUDA_FAIL_ON_MISSING=OFF`** — см. [linux.cmake в Sunshine](../subprojects/sunshine/cmake/compile_definitions/linux.cmake)).

Для стека **CDH + Wayland** без NVFBC часто достаточно корректной сборки с Wayland/VAAPI; точный набор флагов зависит от того, что вы хотите получить на хосте (только NVENC и т.д.).

### 3.5 Ручная конфигурация и сборка (без linux_build.sh)

Из каталога **`subprojects/sunshine`**:

```bash
git submodule update --init --recursive

cmake -B build -G Ninja -S . \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_DOCS=OFF \
  -DBUILD_WERROR=OFF

ninja -C build
```

Полезные опции (см. [`options.cmake`](../subprojects/sunshine/cmake/prep/options.cmake)):

| CMake-опция | Смысл |
|-------------|--------|
| `SUNSHINE_ENABLE_WAYLAND` | Сборка Wayland-захвата (для CDH обычно **ON**) |
| `SUNSHINE_ENABLE_X11` | X11 |
| `SUNSHINE_ENABLE_DRM` | KMS |
| `SUNSHINE_ENABLE_CUDA` | CUDA-специфичный код |
| `SUNSHINE_ENABLE_VAAPI` | VA-API |
| `SUNSHINE_ENABLE_VULKAN` | Vulkan video |
| `BUILD_TESTS` | Тесты |
| `NPM_OFFLINE` | Офлайн-сборка UI (нужен заполненный npm cache) |

Актуальный список опций всегда смотрите в репозитории Sunshine.

### 3.6 KMS и capabilities

Если используете **KMS-захват**, бинарнику часто нужны capabilities (из upstream docs):

```bash
sudo setcap cap_sys_admin,cap_sys_nice+p build/sunshine
```

### 3.7 Упаковка (опционально)

После успешной сборки:

```bash
cd /path/to/cloud-desktop-host/subprojects/sunshine
cpack -G DEB --config ./build/CPackConfig.cmake   # Debian/Ubuntu
cpack -G RPM --config ./build/CPackConfig.cmake   # Fedora
```

---

## 4. Рекомендуемый порядок работ

1. **`git submodule update --init --recursive`** в корне.
2. Собрать **CDH** (`meson` + `ninja` в корне) — проверка wlroots и тулчейна.
3. Собрать **Gamescope** (если нужен Deck-режим из исходников).
4. Собрать **Sunshine** (самый длинный шаг: CMake, npm, возможно CUDA).

Параллельно можно держать установленные из пакетов **Gamescope** и **Sunshine**, а submodules использовать только для **фиксации версий** и патчей.

---

## 5. Типичные сбои

| Симптом | Что проверить |
|---------|----------------|
| Sunshine CMake: не хватает файлов в `third-party/` | `git submodule update --init --recursive` внутри `subprojects/sunshine` |
| Sunshine: ошибка про CUDA | Установить CUDA и `-DCMAKE_CUDA_COMPILER`, или `-DSUNSHINE_ENABLE_CUDA=OFF` |
| Sunshine: ошибки npm / веб-UI | Установлен ли `node`/`npm`, сеть при первой сборке |
| Gamescope: нет subprojects | `git submodule update --init --recursive` внутри `subprojects/gamescope` |
| CDH: нет wlroots | `git submodule update --init subprojects/wlroots` |

---

## 6. Ссылки

- [Sunshine — Building (официально)](https://github.com/LizardByte/Sunshine/blob/master/docs/building.md)
- [Sunshine — options.cmake](https://github.com/LizardByte/Sunshine/blob/master/cmake/prep/options.cmake)
- [Gamescope README](https://github.com/ValveSoftware/gamescope/blob/master/README.md)
