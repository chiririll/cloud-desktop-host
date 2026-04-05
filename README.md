# cloud-desktop-host (CDH)

Headless Wayland-композитор на **wlroots**, ядро стека **облачного рабочего стола** с **[Sunshine](https://github.com/LizardByte/Sunshine)** и **[Moonlight](https://moonlight-stream.org/)**: Plasma через KWin, отдельный режим Steam GamepadUI и режим «Steam Deck» через nested **Gamescope**.

**Репозиторий:** [github.com/wolfam0108/cloud-desktop-host](https://github.com/wolfam0108/cloud-desktop-host)

## Возможности

- Headless output без DRM (удобно для LXC/VM), сокет **`wayland-cd`**
- Согласование **разрешения и FPS** с клиентом Moonlight через D-Bus **`SetOutputMode`** (в т.ч. высокие частоты вроде **144 Hz**)
- **Damage-driven** рендер + heartbeat против starvation для стриминга
- Исправление **refresh в present** для KWin/Gamescope при headless backend
- **PID-фильтр** для `xdg_wm_base` (защита от лишних XDG-клиентов вроде трея Sunshine)
- D-Bus **org.gamescope.Input** для настроек мыши (в т.ч. **scroll factor**) и совместимости с KCM
- Два профиля в Sunshine **`apps`**: **Desktop** и **Steam Deck Mode** (см. `configs/sunshine/apps.json`)

## Документация

| Документ | Содержание |
|----------|------------|
| [Архитектура CDH](docs/Архитектура%20cloud-desktop-host%20%28CDH%29.md) | Архитектура, протоколы, рендер-цикл, D-Bus, ограничения, стриминг и CUDA/NVENC |
| [docs/COMPILATION.md](docs/COMPILATION.md) | Зависимости и сборка CDH |
| [docs/BUILD.md](docs/BUILD.md) | Сборка **всех** субмодулей: CDH, Gamescope, Sunshine |
| [docs/INSTALL_AND_CONFIG.md](docs/INSTALL_AND_CONFIG.md) | Установка, Sunshine, Moonlight, пути и типичные сбои |
| [docs/SUBPROJECTS.md](docs/SUBPROJECTS.md) | **Git submodules**: wlroots, Gamescope |

## Субпроекты (GitHub)

Каталоги `subprojects/wlroots` и `subprojects/gamescope` оформлены как **git submodule** — на GitHub они отображаются как ссылки на конкретные коммиты upstream, а не как «плоские» копии тысяч файлов в одном diff.

```bash
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
# или после обычного clone:
git submodule update --init --recursive
```

Зафиксированные версии (см. `git submodule status`): **wlroots 0.18.3**, **Gamescope 3.16.14.5** (Valve), **Sunshine** (LizardByte, тег вроде `v2026.*` — см. submodule).

Подробная сборка **всех** субмодулей: [docs/BUILD.md](docs/BUILD.md) (CMake/Ninja для Sunshine, Meson для Gamescope, вложенные `git submodule` у Sunshine).

## Быстрый старт (сборка)

```bash
meson setup build
ninja -C build
```

Подробности — в [docs/COMPILATION.md](docs/COMPILATION.md).

## Публикация на GitHub

Репозиторий уже инициализирован с **submodules**. После настройки доступа:

```bash
git remote add origin https://github.com/wolfam0108/cloud-desktop-host.git   # если ещё не добавлен
git push -u origin main
```

При **HTTPS** Git запросит учётные данные; удобнее [SSH](https://docs.github.com/en/authentication/connecting-to-github-with-ssh) или [personal access token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).

Клонирование у других:

```bash
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
```

## Лицензии сторонних проектов

- [wlroots](https://gitlab.freedesktop.org/wlroots/wlroots) — MIT
- [Gamescope](https://github.com/ValveSoftware/gamescope) — см. репозиторий Valve

Код в `src/`, `scripts/`, `tools/` — см. заголовки файлов и политику репозитория (при необходимости добавьте `LICENSE` в корень).
