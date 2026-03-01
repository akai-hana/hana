#!/bin/sh
# Xephyr :1 -screen 2560x1600 +extension RENDER -ac &
Xephyr :25 -screen 2560x1600 +extension RENDER -ac &
# Xephyr :1 -screen 1920x1040 +extension RENDER -ac &
sleep 0.5
DISPLAY=:1 ./zig-out/bin/hana
