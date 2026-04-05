# Субпроекты: wlroots и Gamescope

GitHub **не имеет отдельного типа «Meson subproject»**. Стандартный способ сказать системе Git (и отобразить это на GitHub): **git submodule** — в основном репозитории хранится **запись на конкретный коммит** внешнего репозитория, а каталог в рабочем дереве — **отдельный клон** с собственным `.git` (в виде gitlink).

## Что сейчас в этом репозитории

| Submodule | URL upstream | Зафиксированная версия (тег) |
|-----------|--------------|------------------------------|
| `subprojects/wlroots` | https://gitlab.freedesktop.org/wlroots/wlroots.git | **0.18.3** |
| `subprojects/gamescope` | https://github.com/ValveSoftware/gamescope.git | **3.16.14.5** |

Файл [`.gitmodules`](../.gitmodules) задаёт URL и путь. Точный SHA коммита виден командой:

```bash
git submodule status
```

На GitHub в интерфейсе коммита родительского репозитория строки `subprojects/wlroots` и `subprojects/gamescope` отображаются как **ссылки на коммит** во внешнем репозитории, а не как тысячи файлов в одном diff.

## Клонирование

```bash
git clone --recurse-submodules https://github.com/wolfam0108/cloud-desktop-host.git
```

Если забыли `--recurse-submodules`:

```bash
cd cloud-desktop-host
git submodule update --init --recursive
```

## Обновление версии submodule (осознанно)

Пример для wlroots (перейти на новый тег или коммит):

```bash
cd subprojects/wlroots
git fetch origin
git checkout 0.18.3   # или другой тег/коммит
cd ../..
git add subprojects/wlroots
git commit -m "Bump wlroots to 0.18.3"
```

Аналогично для Gamescope. После обновления **обязательно** пересоберите CDH и проверьте совместимость API wlroots.

## Альтернативы submodule (кратко)

| Подход | Когда уместен |
|--------|----------------|
| **Submodule** | Нужны чёткая версия upstream и нормальный обзор на GitHub |
| **Subtree** | Хотите «влить» историю в один репозиторий без отдельного clone у контрибьюторов |
| **Meson wrap** | Только исходники по URL/tarball без submodule (для wlroots есть официальные wraps) |

Для Gamescope и кастомных патчей часто остаются **submodule** или **форк** с submodule на свой fork.

## Миграция со «встроенного» клона

Если раньше в `subprojects/wlroots` был полный `.git` и вы коммитили всё как монорепозиторий, переход на submodule делается так:

1. Сохраните резервную копию каталога (на случай локальных патчей).
2. Удалите каталог из индекса и с диска (осторожно).
3. Выполните `git submodule add <url> subprojects/wlroots` и `git checkout` нужный тег.
4. Закоммитьте `.gitmodules` и gitlink.

В этом рабочем дереве миграция на submodule уже выполнена при подготовке репозитория к публикации; старые копии при необходимости могли остаться в резервном каталоге вне репозитория.

## Связь с Meson

Корневой [`meson.build`](../meson.build) использует **только** `subproject('wlroots')` — то есть для сборки **cloud-desktop-host** обязателен checkout wlroots в `subprojects/wlroots`.

**Gamescope** в Meson CDH **не** подключается: он нужен как отдельная программа для режима Steam Deck и собирается по инструкциям Valve (или ставится пакетом). Submodule Gamescope фиксирует **версию исходников**, с которой тестировался проект.
