# Сборка cloud-desktop-host

Документ описывает **сборку самого композитора** `cloud-desktop-host` из каталога проекта.

**Полная сборка всех субмодулей** (wlroots как часть CDH, Gamescope, Sunshine с CUDA/CMake/npm и вложенными submodules) вынесена в отдельный файл: **[BUILD.md](BUILD.md)**.

## Зависимости

Соответствуют [`meson.build`](../meson.build) в корне:

| Зависимость | Назначение |
|-------------|------------|
| **meson** (≥ 0.59 для wlroots), **ninja** | Система сборки |
| **gcc** / **clang**, поддержка **C11** и **C++17** | Компиляторы |
| **pkg-config** | Поиск библиотек |
| **wlroots 0.18.3** | Submodule `subprojects/wlroots` (собирается Meson как subproject) |
| **wayland-server** | Протокол сервера Wayland |
| **wayland-protocols** (≥ 1.35) | XML-описания протоколов |
| **libgles2** (GLESv2) | Рендерер wlroots |
| **libinput**, **libudev** | Ввод и устройства |
| **libsystemd** | sd-bus (D-Bus из CDH) |
| **pixman** (через wlroots / зависимости wlroots) | Для wlroots и HUD |

Пример установки пакетов на **Fedora**:

```bash
sudo dnf install meson ninja-build gcc gcc-c++ pkgconf-pkg-config \
  wayland-devel wayland-protocols-devel mesa-libGLES-devel \
  libinput-devel systemd-devel libdrm-devel mesa-libgbm-devel \
  libxkbcommon-devel pixman-devel
```

На других дистрибутивах имена пакетов могут отличаться (`libwayland-dev` в Debian/Ubuntu и т.д.).

## Клонирование с субмодулями

Без wlroots в `subprojects/wlroots` Meson **не** соберёт проект:

```bash
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
cd cloud-desktop-host
```

Если репозиторий уже клонирован без submodules:

```bash
git submodule update --init --recursive
```

Подробнее — [SUBPROJECTS.md](SUBPROJECTS.md).

## Конфигурация и компиляция

Из корня репозитория:

```bash
meson setup build
ninja -C build
```

Результат: исполняемый файл `build/cloud-desktop-host`.

### Пересборка после изменений

```bash
ninja -C build
```

### Чистая пересборка

```bash
rm -rf build
meson setup build
ninja -C build
```

### Установка в префикс (опционально)

```bash
meson setup build --prefix=/usr/local
ninja -C build
sudo ninja -C build install
```

## Утилита `gamescope-focus-daemon`

Исходник: [`tools/gamescope-focus-daemon.c`](../tools/gamescope-focus-daemon.c). Сборка через отдельный вызов компилятора, например:

```bash
gcc -O2 -o gamescope-focus-daemon tools/gamescope-focus-daemon.c $(pkg-config --cflags --libs x11)
```

Точные флаги зависят от окружения; при необходимости оформите отдельный `meson.build` в `tools/`.

## Типичные ошибки

- **`meson: command not found`** — установите `meson` и `ninja`.
- **Не найден wlroots** — выполните `git submodule update --init subprojects/wlroots`.
- **Отсутствует wayland-protocols** — пакет с XML-протоколами (не путать с `wayland-server`).
- **GLES/renderer** — для headless часто нужны Mesa и корректный доступ к `/dev/dri` (в контейнере — проброс GPU и права).

## Сборка Gamescope (справочно)

Submodule `subprojects/gamescope` — полноценное дерево Valve **Gamescope**. Сборка описана в upstream (зависимости Vulkan, glm, stb, wlroots как subproject Gamescope и т.д.). Для продакшена часто проще ставить пакет дистрибутива и держать submodule только для **версии и патчей**.
