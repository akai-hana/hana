### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing

when i write a long prompt that doesn't completely fit in the bar, and i enter normal mode, as i go towards the right, the ellipsis in view will move one char to the right, kind of clipping on the "[NORMAL]" indicator. as i go more to the right, a sort of tiny gap to the left of the selected character inside my cursor's box will be in view, something that doesn't happen anywhere else but as i go towards the right of a prompt text that doesn't completely fit inside the segment's view. can you please fix these two minor bugs?

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
