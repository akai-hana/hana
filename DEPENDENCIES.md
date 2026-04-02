message on a clean linux install. pending to extract complete list of dependencies onto README.md

❯ zig build -Drelease=true --color on --error-style minimal 2>&1
compile exe hana ReleaseFast native failure
error: error: unable to find dynamic system library 'X11' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libX11.so
         /usr/local/lib/libX11.a
         /usr/lib/x86_64-linux-gnu/libX11.so
         /usr/lib/x86_64-linux-gnu/libX11.a
         /lib64/libX11.so
         /lib64/libX11.a
         /lib/libX11.so
         /lib/libX11.a
         /usr/lib64/libX11.so
         /usr/lib64/libX11.a
         /usr/lib/libX11.so
         /usr/lib/libX11.a
         /lib/x86_64-linux-gnu/libX11.so
         /lib/x86_64-linux-gnu/libX11.a
       error: unable to find dynamic system library 'xcb' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libxcb.so
         /usr/local/lib/libxcb.a
         /usr/lib/x86_64-linux-gnu/libxcb.so
         /usr/lib/x86_64-linux-gnu/libxcb.a
         /lib64/libxcb.so
         /lib64/libxcb.a
         /lib/libxcb.so
         /lib/libxcb.a
         /usr/lib64/libxcb.so
         /usr/lib64/libxcb.a
         /usr/lib/libxcb.so
         /usr/lib/libxcb.a
         /lib/x86_64-linux-gnu/libxcb.so
         /lib/x86_64-linux-gnu/libxcb.a
       error: unable to find dynamic system library 'xcb-cursor' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libxcb-cursor.so
         /usr/local/lib/libxcb-cursor.a
         /usr/lib/x86_64-linux-gnu/libxcb-cursor.so
         /usr/lib/x86_64-linux-gnu/libxcb-cursor.a
         /lib64/libxcb-cursor.so
         /lib64/libxcb-cursor.a
         /lib/libxcb-cursor.so
         /lib/libxcb-cursor.a
         /usr/lib64/libxcb-cursor.so
         /usr/lib64/libxcb-cursor.a
         /usr/lib/libxcb-cursor.so
         /usr/lib/libxcb-cursor.a
         /lib/x86_64-linux-gnu/libxcb-cursor.so
         /lib/x86_64-linux-gnu/libxcb-cursor.a
       error: unable to find dynamic system library 'xcb-keysyms' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libxcb-keysyms.so
         /usr/local/lib/libxcb-keysyms.a
         /usr/lib/x86_64-linux-gnu/libxcb-keysyms.so
         /usr/lib/x86_64-linux-gnu/libxcb-keysyms.a
         /lib64/libxcb-keysyms.so
         /lib64/libxcb-keysyms.a
         /lib/libxcb-keysyms.so
         /lib/libxcb-keysyms.a
         /usr/lib64/libxcb-keysyms.so
         /usr/lib64/libxcb-keysyms.a
         /usr/lib/libxcb-keysyms.so
         /usr/lib/libxcb-keysyms.a
         /lib/x86_64-linux-gnu/libxcb-keysyms.so
         /lib/x86_64-linux-gnu/libxcb-keysyms.a
       error: unable to find dynamic system library 'xkbcommon' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libxkbcommon.so
         /usr/local/lib/libxkbcommon.a
         /usr/lib/x86_64-linux-gnu/libxkbcommon.so
         /usr/lib/x86_64-linux-gnu/libxkbcommon.a
         /lib64/libxkbcommon.so
         /lib64/libxkbcommon.a
         /lib/libxkbcommon.so
         /lib/libxkbcommon.a
         /usr/lib64/libxkbcommon.so
         /usr/lib64/libxkbcommon.a
         /usr/lib/libxkbcommon.so
         /usr/lib/libxkbcommon.a
         /lib/x86_64-linux-gnu/libxkbcommon.so
         /lib/x86_64-linux-gnu/libxkbcommon.a
       error: unable to find dynamic system library 'xkbcommon-x11' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libxkbcommon-x11.so
         /usr/local/lib/libxkbcommon-x11.a
         /usr/lib/x86_64-linux-gnu/libxkbcommon-x11.so
         /usr/lib/x86_64-linux-gnu/libxkbcommon-x11.a
         /lib64/libxkbcommon-x11.so
         /lib64/libxkbcommon-x11.a
         /lib/libxkbcommon-x11.so
         /lib/libxkbcommon-x11.a
         /usr/lib64/libxkbcommon-x11.so
         /usr/lib64/libxkbcommon-x11.a
         /usr/lib/libxkbcommon-x11.so
         /usr/lib/libxkbcommon-x11.a
         /lib/x86_64-linux-gnu/libxkbcommon-x11.so
         /lib/x86_64-linux-gnu/libxkbcommon-x11.a
       error: unable to find dynamic system library 'cairo' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libcairo.so
         /usr/local/lib/libcairo.a
         /usr/lib/x86_64-linux-gnu/libcairo.so
         /usr/lib/x86_64-linux-gnu/libcairo.a
         /lib64/libcairo.so
         /lib64/libcairo.a
         /lib/libcairo.so
         /lib/libcairo.a
         /usr/lib64/libcairo.so
         /usr/lib64/libcairo.a
         /usr/lib/libcairo.so
         /usr/lib/libcairo.a
         /lib/x86_64-linux-gnu/libcairo.so
         /lib/x86_64-linux-gnu/libcairo.a
       error: unable to find dynamic system library 'pangocairo-1.0' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libpangocairo-1.0.so
         /usr/local/lib/libpangocairo-1.0.a
         /usr/lib/x86_64-linux-gnu/libpangocairo-1.0.so
         /usr/lib/x86_64-linux-gnu/libpangocairo-1.0.a
         /lib64/libpangocairo-1.0.so
         /lib64/libpangocairo-1.0.a
         /lib/libpangocairo-1.0.so
         /lib/libpangocairo-1.0.a
         /usr/lib64/libpangocairo-1.0.so
         /usr/lib64/libpangocairo-1.0.a
         /usr/lib/libpangocairo-1.0.so
         /usr/lib/libpangocairo-1.0.a
         /lib/x86_64-linux-gnu/libpangocairo-1.0.so
         /lib/x86_64-linux-gnu/libpangocairo-1.0.a
       error: unable to find dynamic system library 'pango-1.0' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libpango-1.0.so
         /usr/local/lib/libpango-1.0.a
         /usr/lib/x86_64-linux-gnu/libpango-1.0.so
         /usr/lib/x86_64-linux-gnu/libpango-1.0.a
         /lib64/libpango-1.0.so
         /lib64/libpango-1.0.a
         /lib/libpango-1.0.so
         /lib/libpango-1.0.a
         /usr/lib64/libpango-1.0.so
         /usr/lib64/libpango-1.0.a
         /usr/lib/libpango-1.0.so
         /usr/lib/libpango-1.0.a
         /lib/x86_64-linux-gnu/libpango-1.0.so
         /lib/x86_64-linux-gnu/libpango-1.0.a
       error: unable to find dynamic system library 'glib-2.0' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libglib-2.0.so
         /usr/local/lib/libglib-2.0.a
         /usr/lib/x86_64-linux-gnu/libglib-2.0.so
         /usr/lib/x86_64-linux-gnu/libglib-2.0.a
         /lib64/libglib-2.0.so
         /lib64/libglib-2.0.a
         /lib/libglib-2.0.so
         /lib/libglib-2.0.a
         /usr/lib64/libglib-2.0.so
         /usr/lib64/libglib-2.0.a
         /usr/lib/libglib-2.0.so
         /usr/lib/libglib-2.0.a
         /lib/x86_64-linux-gnu/libglib-2.0.so
         /lib/x86_64-linux-gnu/libglib-2.0.a
       error: unable to find dynamic system library 'gobject-2.0' using strategy 'paths_first'. searched paths:
         /usr/local/lib/libgobject-2.0.so
         /usr/local/lib/libgobject-2.0.a
         /usr/lib/x86_64-linux-gnu/libgobject-2.0.so
         /usr/lib/x86_64-linux-gnu/libgobject-2.0.a
         /lib64/libgobject-2.0.so
         /lib64/libgobject-2.0.a
         /lib/libgobject-2.0.so
         /lib/libgobject-2.0.a
         /usr/lib64/libgobject-2.0.so
         /usr/lib64/libgobject-2.0.a
         /usr/lib/libgobject-2.0.so
         /usr/lib/libgobject-2.0.a
         /lib/x86_64-linux-gnu/libgobject-2.0.so
         /lib/x86_64-linux-gnu/libgobject-2.0.a

error: process exited with error code 1
