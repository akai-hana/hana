### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing 
---

## active TODOs

(HALFWAY) translate all dwm binds from config.h to my config.toml

make zig build compilation be done onto /usr/bin, or /bin, instead of /zig-out. if compilation to either of those dirs fails, create and build onto ./bin, instead of ./zig-out/bin

vim.zig: make buffer memory-constraint constants be dynamically allocated memory buffers instead.

when i have a tiled window, i disable tiling, then switch workspaces, it is suddenly gone out of view on my display. however, if i do mod+middle-click onto a tiled window, turning it from tiled to floating, and switch workspaces, it still looks fine after i return. i want coordinates of all windows to be tracked properly. can you please solve this edge case?

right now, when i disable tiling with mod+n, all windows behave weirdly: their origin coordinate get moved slightly down and right, so they're clipping beyond the right and bottom part of the display, but most of the window is still visible. why does this happen?

when my border width is set at 50%, it's as if it was set to 100%. same with gaps. can you verify that the calculation logic is correct?

i want you to add an extra layer to window borders and bar, one that overlaps them, but in contrast to the current layers, they aren't composited by a compositor like picom. the reason i want this to happen is,

when i transfer focus to a window by clicking instead of hovering (when hovering for focus doesn't work, and only clicking transfers focus), the bar updates the window background color very slowly, from unfocused color to focused color. sometimes it takes a lot, other times it's almost instant. i suspect there's some kind of polling going on maybe? either way, the logic is definitely wrong, as this updating should be instant. can you please look at the source code and figure this minor visual bug out?

when i have two windows on my screen, master and slave, and then i open a third one, which is the second slave, and then close this third window while my cursor isn't touching any windows, the focus gets transferred to the master, not the first slave, when the slave was the window that last had focus. can you please address this and make it so that the last window having focus regains it on a window kill of the next window?

when doing mod+tab and mod+shift+tab, dont let cursor steal window focus

i want any tiling layouts not defined in the array to not be available on runtime. right now, i have fibonacci commented out on the layout array, but it still appears on runtime. can you please fix this?

when i'm in the monocle tiling layout, and i open a new window, the previous window will stay on the same coordinates, overlapped by the new window i just opened. when i switch workspaces to a different one, and then come back, this is not the case anymore; in this monocle layout, the previous window has moved to outside of the display, while my most recent one remains. when i close this most recent window, the previous one does come back and get displayed. i want you to change this current behavior, so that immediately upon spawning and mapping the window on the display while under the monocle tiling layout, the previous window doesn't just remain under it, and gets moved to the same place that it's now being moved when i manually trigger this through a workspace change back and forth. this is important since transparent windows are see-through, so this isn't an invisible operation to the user; thus, behavior should be consistent in the way i just described.

when i do mod+left click on a window, it will immediately go to floating mode, regardless of whether i moved it with my cursor or not. maybe i could accidentally left click on a window while pressing mod, but quickly let go because that wasn't my intention. can you make it so that the window only goes onto floating mode the moment i move it with my mouse, even a single pixel? thanks.

if i spawn a window in a workspace and then quickly move onto another workspace, on weak machines where the program im opening will take a bit to open, will open on the workspace i switched to and currently am, instead of the workspace i originally spawned this window at. i want this behavior to stop, and if a program is summoned in a specific workspace, for it to be opened on that workspace, regardless of how long the program's window takes to open.

please add a dedicated layout to making windows floating. so, instead of doing mod+n (.toggle_tiling => tiling.toggleTiling(wm),) to stop tiling, floating mode will become just another layout the user can cycle in and out of, enable or disable in the config.toml, etc etc.

can you make it so that if i set transparency to 100, that all the transparency logic isn't processed at all, and the wm instead renders a regular RGB bar, skipping argb and 32 bits and all that? this is to avoid any unneeded computational processing when the user doesn't want transparency to begin with.

make a color theme that pulls in the xresources colors and makes a theme with them.

make a new themes dir inside src/ where color themes will be defined as .toml files, and will simply be fused with config.toml when being parsed. we can make it so that we can still define colors in config.toml this way, but if not defined in config.toml, pull them from the theme, which we define similarly to how we define the custom tiling layout now. (theme = "xresources" # or something like this))

add a colors/ dir to set color themes

go through the entire file again and verify whether there's any remaining opportunities to sort the file's contents' order, so that it is in the order that makes the most sense.

go through each file systematically and make it as professionably presentable as possible, ready to be deployed as a production codebase. do everything that involves that statement, as well as making sure that each function is properly commented; not over-commenting yet still documenting everything properly; explaining not just what something is, but why. you should as well analyze the ordering of the functions/methods, constructs, enums, and every other segment of code, analyzing whether the current ordering makes the most sense, and if a different one would make the file's code clearer or more organized, sort them accordingly, replying with the files with the changes applied. finally, you should go through each function/enum/construct/etc's code, and analyze the ordering within each. then, determine whether the ordering is the most optimal or not, and sort where accordingly. you can also group together different related elements within a segment to further contribute to the cause of creating the most optimal order. be as thorough and in-depth as possible, going through each step really carefully; time or resource saving doesn't matter. follow best coding practices.

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

