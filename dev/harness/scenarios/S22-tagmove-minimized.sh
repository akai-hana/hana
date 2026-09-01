# S22 - tagmove-minimized (BC12): a minimized record's restore target follows
# the window's current tag/workspace, never leaking back to the origin ws.
#
# move_to_workspace retargets a window's mask; restore ('unminimize_lifo')
# resolves its destination as lowestBit(mask). So a window moved to ws2 and
# then minimized must restore on ws2 -- and must NOT reappear on ws1 when an
# unminimize is issued from ws1.
spawn_client A
spawn_client B          # B stays on ws1 as a distraction stack
key super+shift+2       # move focused A to ws2 (mask -> bit(2))
settle 300
key super+2             # switch to ws2; A is focused here
settle 300
key super+t             # minimize A on ws2 (record tagged ws2)
settle 300
dump minimized-on-ws2   # A parked; ws2 empty of visible windows
state_dump
key super+1             # back to ws1
settle 300
key super+shift+t       # unminimize_lifo on ws1: nothing minimized here -> no-op
settle 400
dump ws1-untouched      # B stack unchanged; A must NOT pop onto ws1
key super+2
settle 300
key super+shift+t       # unminimize_lifo on ws2 -> A restores into ws2's slot
settle 400
dump restored-on-ws2    # A present on ws2; record followed the move
state_dump
