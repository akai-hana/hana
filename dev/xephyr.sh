#!/bin/sh
Xephyr -ac -screen 2560x1600 -br -reset -dpi 256 :1 &
sleep 0.1
DISPLAY=:1 ~/git/hana/zig-out/bin/hana
