### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing

how to switch to floating layout? (><>)

in debug.zig, drop "info:" messages, and just display the [<name>] tags in place. make these tags have the same color that "info:" currently does.

when i cycle between layouts using toggleLayout/toggleLayoutReverse (core.zig, config.zig, input.zig), please make it so that mouse hovering doesn't steal focus at windows being re-positioned, if it was previously positioned on one window but the layout cycling made it touch a different one. (focus.zig, window.zig, tracking.zig)

per worspace layout also include per workspace master count

when doing toggle_float (mod+middle_click), i want the window to be tiled to the area where it is closest to. what this means is that, if there's already another window tiled, and i do toggle_float with the floating window located onto the left half of the screen, then it should be tiled onto the left. if it's to the right, then tiled to the right. you should take its middle/center of the floating window to be tiled, and decide where to tile it based off of that coordinates. it should work on any tiling layout. 
opening a window bound to a specific workspace from a different workspace, while the workspace it is bound to contains a fullscreened window, switching to this workspace and un-fullscreening this window makes it so that there's a gap where the spawned bound window should be, but actually isn't: all there is, is only a blank gap where it would be tiled. switching workspaces back and forth re-triggers a tiling event, which fixes this and makes the bound window appear correctly. could you please fix this minor bug?

when i write a long prompt that doesn't completely fit in the bar, when i hit the top and the prompt text starts to move to the left to accomodate the new text, the cursor line moves one character to the right. why is this?

could you reinforce the window killing system, checking if it really did get closed? right now it only uses graceful closing, but the window may be unresponsive and ignore it; on these cases, i want you to forcefully kill the window (maybe sending a kill signal, or some other way).

improve fallback defaults

when my border width is set at 50%, it's as if it was set to 100%. same with gaps. can you verify that the calculation logic is correct?

i want you to add an extra layer to window borders and bar, one that overlaps them, but in contrast to the current layers, they aren't composited by a compositor like picom. the reason i want this to happen is,

please add a dedicated layout to making windows floating. so, instead of doing mod+n (.toggle_tiling => tiling.toggleTiling(wm),) to stop tiling, floating mode will become just another layout the user can cycle in and out of, enable or disable in the config.toml, etc etc.

can you make it so that if i set transparency to 100, that all the transparency logic isn't processed at all, and the wm instead renders a regular RGB bar, skipping argb and 32 bits and all that? this is to avoid any unneeded computational processing when the user doesn't want transparency to begin with.

bspwm leaf layout {
"modern" layout: bar at the top, workspaces at the middle, date at the right, system resources at the left, and big spacing in-between (don't make it expanding, but instead static, where each segment is bound to left/right/center, and any gap that remains, remains a gap, isn't filled.)

window spawning in this layout is dependant on what the current window focused is: if no windows within workspace, just spawn one regularly, the second one will make both split, the third one will split the right one to a top half and the spawned to the bottom half of the right segment of the display. Up to now it is basically like master-stack layout. the thing is, if i were focusing the left window when i had two windows open, the split would've happened on that window, on the left half. any subsequent splits happen according to the currently focused window, following the horizontal/vertical split criteria mentioned earlier.

if window is higher than it is wider, slice it in half, leaving a top and bottom window; if it is wider than higher, slice it in half, leaving a left and right window.
}

## BIG FEATURES (avoid for now)

some sort of window animations? though this is crazy work, do it at the very end
