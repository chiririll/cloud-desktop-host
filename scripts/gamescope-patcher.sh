#!/bin/bash
# gamescope-patcher.sh — Эмуляция внутреннего дисплея Steam Deck
# Запускается от имени user.

patch_display() {
    local dpy=$1
    export DISPLAY=$dpy
    echo "[patcher] Patching $DISPLAY..."

    # 1. Форсируем внутренний дисплей
    xprop -root -f GAMESCOPE_DISPLAY_FORCE_INTERNAL 32c -set GAMESCOPE_DISPLAY_FORCE_INTERNAL 1
    xprop -root -f GAMESCOPE_DISPLAY_IS_EXTERNAL 32c -set GAMESCOPE_DISPLAY_IS_EXTERNAL 0
    
    # 2. Частоты (даже если они внешние, Steam может их подхватить)
    MODES="1920x1080@30000 1920x1080@60000 1920x1080@90000 1920x1080@120000"
    xprop -root -f GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL 8s -set GAMESCOPE_DISPLAY_MODE_LIST_EXTERNAL "$MODES"
    
    # 3. Фильтры масштабирования (Scaling)
    # 0 = AUTO, 1 = INTEGER, 2 = FIT, 3 = FILL, 4 = STRETCH, 5 = FSR, 6 = NIS
    xprop -root -f GAMESCOPE_SCALING_FILTER 32c -set GAMESCOPE_SCALING_FILTER 1
    
    # 4. Прочие параметры
    xprop -root -f GAMESCOPE_VRR_CAPABLE 32c -set GAMESCOPE_VRR_CAPABLE 1
    xprop -root -f GAMESCOPE_DISPLAY_SUPPORTS_HDR 32c -set GAMESCOPE_DISPLAY_SUPPORTS_HDR 1
    xprop -root -f GAMESCOPE_FPS_LIMIT 32c -set GAMESCOPE_FPS_LIMIT 60
    
    echo "[patcher] Atoms updated for $DISPLAY"
}

patch_display ":0"
patch_display ":1"
