# S23 - crossws-restore (BC10): a specific restore issued while sitting on a
# workspace that holds no minimized windows must leave BOTH that workspace's
# visible stack AND the parked records minimised on other workspaces untouched.
spawn_client A
spawn_client B
key super+t; settle 300  # minimize A (parked on ws1)
key super+t; settle 300  # minimize B (parked on ws1)
dump ws1-all-minimized   # A,B parked; focus fallen back cleanly
state_dump
key super+2              # switch to ws2 (empty)
settle 300
spawn_client C
spawn_client D
settle 300
dump ws2-before-restore  # C,D tiled on ws2
key super+shift+t        # unminimize_lifo from ws2: no minimized windows here
settle 400
dump ws2-after-restore   # C,D undisturbed; A,B not pulled across (current ws intact)
state_dump
key super+1              # back to ws1
settle 300
dump ws1-still-minimized # A,B remain parked; cross-ws restore left records intact
state_dump
