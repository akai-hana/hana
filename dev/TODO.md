### hana's TODO list! ###
# In here i write the things i want to do to not lose track of the different ideas i come up with while developing

# *** #
when im resizing a window, as i go to the horizontal middle of a window and past that, i want the resizing to wrap around and make the window grow bigger to the opposite side, and same with vertical middle, make it grow/resize the opposite side. basically mirror the corner it is resizing.
# *** #

# ### EDGE CASES ### #

- make it so that when doing mod+shift+f while a prompt is currently ongoing, if cursor is hovering over the bar it should kill the prompt, but if it's hovering over no window nothing happens, or a program's window it should kill that window; it should not in all cases kill the prompt no matter where the cursor is.

# ### HIGH-LEVEL CHANGES ### #

+ decouple prompt.zig from vim.zig
  - the issue at hand is that prompt.zig is very tightly coupled with vim.zig, so that if i wanted to make vim.zig an optional module on my window manager, in prompt.zig i should either create tons of empty stubs guarded against build.zig's comprobation of whether vim.zig is present in the codebase or not, or to guard every vim.zig call within the code as comptime (e.g. "if (comptime build.has_vim)"). the former leads to hard-coding lots of functions, making the window manager more rigid and tedious to modify, while the latter bloats and muddies the code. because of this, i'd like to re-code vim.zig in a way so that, for example, there is, for example, only one master function in charge of processing keys, and then the guard is at prompt.zig's highest possible level, so that i only end up needing one comptime guard at the entire vim modekey routing function within prompt.zig. can you please evaluate whether this proposal is both possible and viable? 
- make windows.zig be able to exist without tiling
- make tiling unconditional between tiling.zig and layout.zig

# ### MISC ### #

- are build.zig's "is_segment" optional subsystem property truly necessary? is there no way to rewrite the code so that there is no need for this property?

- fix mod+n cycling onto floating layout, not just making the focused window floating

- when cycling between layouts using toggleLayout/toggleLayoutReverse (core.zig, config.zig, input.zig), please make it so that mouse hovering doesn't steal focus at windows being re-positioned, if it was previously positioned on one window but the layout cycling made it touch a different one. (focus.zig, window.zig, tracking.zig)

- when doing toggle_float (mod+middle_click), i want the window to be tiled to the area where it is closest to. what this means is that, if there's already another window tiled, and i do toggle_float with the floating window located onto the left half of the screen, then it should be tiled onto the left. if it's to the right, then tiled to the right. you should take its middle/center of the floating window to be tiled, and decide where to tile it based off of that coordinates. it should work on any tiling layout. 

- opening a window bound to a specific workspace from a different workspace, while the workspace it is bound to contains a fullscreened window, switching to this workspace and un-fullscreening this window makes it so that there's a gap where the spawned bound window should be, but actually isn't: all there is, is only a blank gap where it would be tiled. switching workspaces back and forth re-triggers a tiling event, which fixes this and makes the bound window appear correctly. could you please fix this minor bug?

- could you reinforce the window killing system, checking if it really did get closed? right now it only uses graceful closing, but the window may be unresponsive and ignore it; on these cases, i want you to forcefully kill the window (maybe sending a kill signal, or some other way).

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
