### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing

when i spawn a window bound to workspace 1, while there's a full-screened window in workspace 1, and i'm currently in a different workspace, when i go back to workspace 1 and un-fullscreen this window, it will tile to the left, with a gap covering the right half of the screen, where the bound window i spawned should be tiled, but instead is an empty gap. switching workspaces back and forth onto workspace 1 triggers a window re-tiling and solves this issue, filling the gap with the bound window i spawned. can you please handle this edge-case causing this visual bug?

carroussel title: when the bar is hidden, pause the carroussel. this includes switching to another workspace, or hiding bar, or entering full-screen.

make zig build compilation be done onto /usr/bin, or /bin, instead of /zig-out. if compilation to either of those dirs fails, create and build onto ./bin, instead of ./zig-out/bin

vim.zig: make buffer memory-constraint constants be dynamically allocated memory buffers instead.

when i have a tiled window, i disable tiling, then switch workspaces, it is suddenly gone out of view on my display. however, if i do mod+middle-click onto a tiled window, turning it from tiled to floating, and switch workspaces, it still looks fine after i return. i want coordinates of all windows to be tracked properly. can you please solve this edge case?

right now, when i disable tiling with mod+n, all windows behave weirdly: their origin coordinate get moved slightly down and right, so they're clipping beyond the right and bottom part of the display, but most of the window is still visible. why does this happen?

when my border width is set at 50%, it's as if it was set to 100%. same with gaps. can you verify that the calculation logic is correct?

i want you to add an extra layer to window borders and bar, one that overlaps them, but in contrast to the current layers, they aren't composited by a compositor like picom. the reason i want this to happen is,

when i transfer focus to a window by clicking instead of hovering (when hovering for focus doesn't work, and only clicking transfers focus), the bar updates the window background color very slowly, from unfocused color to focused color. sometimes it takes a lot, other times it's almost instant. i suspect there's some kind of polling going on maybe? either way, the logic is definitely wrong, as this updating should be instant. can you please look at the source code and figure this minor visual bug out?

when i have two windows on my screen, master and slave, and then i open a third one, which is the second slave, and then close this third window while my cursor isn't touching any windows, the focus gets transferred to the master, not the first slave, when the slave was the window that last had focus. can you please address this and make it so that the last window having focus regains it on a window kill of the next window?

when i do mod+left click on a window, it will immediately go to floating mode, regardless of whether i moved it with my cursor or not. maybe i could accidentally left click on a window while pressing mod, but quickly let go because that wasn't my intention. can you make it so that the window only goes onto floating mode the moment i move it with my mouse, even a single pixel? thanks.

please add a dedicated layout to making windows floating. so, instead of doing mod+n (.toggle_tiling => tiling.toggleTiling(wm),) to stop tiling, floating mode will become just another layout the user can cycle in and out of, enable or disable in the config.toml, etc etc.

can you make it so that if i set transparency to 100, that all the transparency logic isn't processed at all, and the wm instead renders a regular RGB bar, skipping argb and 32 bits and all that? this is to avoid any unneeded computational processing when the user doesn't want transparency to begin with.

make a color theme that pulls in the xresources colors and makes a theme with them.

make a new themes dir inside src/ where color themes will be defined as .toml files, and will simply be fused with config.toml when being parsed. we can make it so that we can still define colors in config.toml this way, but if not defined in config.toml, pull them from the theme, which we define similarly to how we define the custom tiling layout now. (theme = "xresources" # or something like this))

add a colors/ dir to set color themes

---

## LONG TERM

LONG TERM: somehow make vertical layout left and right

LONG TERM: code a similar tool to drun, replace it instead of rofi in config.toml

---

## bspwm leaf layout

"modern" layout: bar at the top, workspaces at the middle, date at the right, system resources at the left, and big spacing in-between (don't make it expanding, but instead static, where each segment is bound to left/right/center, and any gap that remains, remains a gap, isn't filled.)

window spawning in this layout is dependant on what the current window focused is: if no windows within workspace, just spawn one regularly, the second one will make both split, the third one will split the right one to a top half and the spawned to the bottom half of the right segment of the display. Up to now it is basically like master-stack layout. the thing is, if i were focusing the left window when i had two windows open, the split would've happened on that window, on the left half. any subsequent splits happen according to the currently focused window, following the horizontal/vertical split criteria mentioned earlier.

if window is higher than it is wider, slice it in half, leaving a top and bottom window; if it is wider than higher, slice it in half, leaving a left and right window.

## BIG FEATURES (avoid for now)

some sort of window animations? though this is crazy work, do it at the very end
