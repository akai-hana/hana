### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing

89sk: [2 PM] continue; finish slow spawning resolving
iesfm: [3 PM] continue; make tiling and floating optional, mandatory one minimum

# *** #
- fix mod+n cycling onto floating layout, not just making the focused window floating
# *** #

# ### MISC ### #

- when cycling between layouts using toggleLayout/toggleLayoutReverse (core.zig, config.zig, input.zig), please make it so that mouse hovering doesn't steal focus at windows being re-positioned, if it was previously positioned on one window but the layout cycling made it touch a different one. (focus.zig, window.zig, tracking.zig)

- when doing toggle_float (mod+middle_click), i want the window to be tiled to the area where it is closest to. what this means is that, if there's already another window tiled, and i do toggle_float with the floating window located onto the left half of the screen, then it should be tiled onto the left. if it's to the right, then tiled to the right. you should take its middle/center of the floating window to be tiled, and decide where to tile it based off of that coordinates. it should work on any tiling layout. 

- reinforce the window killing system, checking if it really did get closed? right now it only uses graceful closing, but the window may be unresponsive and ignore it; on these cases, i want you to forcefully kill the window (maybe sending a kill signal, or some other way).

- revise fallback.toml
  + fallback.toml is completely unupdated. pending to make up-to-date with latest config changes.

+ add additional layering to borders and bar 
  - right now, both window borders and the bar are rendered with raw xcb calls (xcb_poly_fill_rectangle). this is due to the fact that the shapes are really simple, and also because using this method makes it so that, when compositing the window manager with something like picom, both the borders and bar become translucent when picom has transparency enabled, so adding that and also gaussian blur makes these elements of the wm really cool looking. the issue with this is that, through picom's compositing, windows are blended such that 

+ double layer window borders and bar's xcb poly fills
  - with this i expect to accomplish a visual effect where the background takes background color less into account for the calculation of its linear alpha blending, so that colors don't look so washed up behind bright background colors

does this window manager have a mechanism in place so that if i set transparency to 100, that all the transparency logic isn't processed at all, and the wm instead renders a regular RGB bar, skipping argb and 32 bits and all that?

+ bspwm leaf layout
  - modern" layout: bar at the top, workspaces at the middle, date at the right, system resources at the left, and big spacing in-between (don't make it expanding, but instead static, where each segment is bound to left/right/center, and any gap that remains, remains a gap, isn't filled.)
  - window spawning in this layout is dependant on what the current window focused is: if no windows within workspace, just spawn one regularly, the second one will make both split, the third one will split the right one to a top half and the spawned to the bottom half of the right segment of the display. Up to now it is basically like master-stack layout. the thing is, if i were focusing the left window when i had two windows open, the split would've happened on that window, on the left half. any subsequent splits happen according to the currently focused window, following the horizontal/vertical split criteria mentioned earlier.
  - if window is higher than it is wider, slice it in half, leaving a top and bottom window; if it is wider than higher, slice it in half, leaving a left and right window.
