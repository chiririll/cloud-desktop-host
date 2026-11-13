/* Include-обёртка для wlroots-заголовков в C++ (пара с wlr_cxx_end.h).
 * Заголовки wlroots 0.19+ содержат `float m[static 9]` — C99-only синтаксис.
 * Пустой `static` превращает его в `float m[9]`; inline-функции остаются inline. */
/* C++-хедеры libstdc++ (и обёртки <math.h> → <cmath>) подтягиваются из C-заголовков
 * wayland/wlroots — они должны быть включены ДО того, как `static` станет пустым. */
#include <cmath>
#include <math.h>
#include <string>
#include <vector>
#include <map>
#include <mutex>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <sys/types.h>
#define static
