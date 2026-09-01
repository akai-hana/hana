# hana smoke-test harness

Behavioral verification for the window manager: each scenario boots a private
Xvfb server and a fresh hana instance with a controlled config, drives it with
synthetic input (`xdotool`), and records X-side truth (`xwininfo`, `xprop`)
plus hana's own state dumps. Outputs are normalized (window IDs -> stable
tokens, PIDs/times scrubbed) so runs are diffable.

> **NOTE (goldens):** S02/S04/S05/S16 diverged from their recorded goldens
> after the intentional **T36 close-fallback** behavior change. `--compare`
> reports DIFF for these until their goldens are re-recorded (`./run-scenario.sh
> --golden S02 S04 S05 S16`). This is expected, not a regression; see
> `ARCHITECTURE.md` ("Behavioral gates") for details.

## Requirements

| Tool      | Used for                        | Missing? |
|-----------|---------------------------------|----------|
| Xvfb      | headless X server               | required |
| xdotool   | synthetic keys/mouse, searches  | required |
| xwininfo  | geometry/stacking truth         | required |
| xprop     | root/EWMH properties            | required |
| perl      | output normalization            | required |
| cc + X11  | `tools/setbw.c` (S12 only)      | S12 skips gracefully |

`xephyr`/`wmctrl` are NOT needed: interactive debugging uses `--keep`
(see below) instead of Xephyr; desktop-hint assertions use `xprop` directly.
Note for this machine's Xvfb build: the screen size needs an explicit screen
number (`-screen 0 1280x800x24`), already handled by the runner.

## Usage

```sh
zig build                        # default build is Debug: dump_state/info logs need it
cd dev/harness
./run-scenario.sh S01-spawn-tiled              # run one scenario
./run-scenario.sh S01-spawn-tiled S10-fs-cycle # several
./run-scenario.sh --golden S01-spawn-tiled     # record goldens
./run-scenario.sh --compare $(ls scenarios | sed 's/\.sh//')  # parity run
./run-scenario.sh --keep S03-min-restore       # leave Xvfb+hana alive for poking
```

Artifacts per scenario land in `out/<SC>/`: `snap-<label>.tree(.raw|.norm)`
(geometry snapshots), `snap-<label>.props.*`, `hana.log.norm` (hana stderr,
including `STATE DUMP` blocks triggered by Mod+Q), `bench.txt`.
Goldens live in `golden/<SC>/`; `--compare` diffs new normalized output
against them.

## Scenarios and behavioral contract

| Scenario | Contract rows |
|---|---|
| S01 spawn-tiled | BC01 (spawn path basics) |
| S02 close | relayout on destroy |
| S03 min-restore | BC06, BC07 |
| S04 min-from-fs | BC08, BC13, BC14 |
| S05 restore-all | BC09 |
| S06 switch-basic | BC15 |
| S07 pinned | BC16 |
| S08 all-view | BC17 |
| S09 tag-move | BC18 |
| S10 fs-cycle | BC14 (hard gate) |
| S11 configure-honored | BC03 |
| S12 client-bw | BC04, BC05 |
| S13 reload | BC20 |
| S14 drag-snap | BC21 |
| S15 monocle-focus | BC07, BC22 |
| S16 close-respawn | P0-1: no registry leak on close (ghosts/phantom slots) |
| S17 hover-focus | P0-2: EnterNotify focuses (registry resolves managed windows) |
| S18 ewmh-fullscreen | P0-3: client-message `_NET_WM_STATE` fullscreen path |
| S19 fullscreen-toggle | ND-14: ConfigureRequest decision paths around fullscreen |
| S20 layout-storm | SW-9/S14F10: layout cycling + master-count clamp extremes |
| S21 hints-resize | SW-9/S14F10: hint clamp on fixed-size clients |

Known coverage gaps (contracts with no deterministic keybind-expressible
scenario): BC10 (cross-ws *specific* restore — `unminimize_*` restores to the
current ws, not a window's home), BC12 (tag-move of a minimized window —
`move_to_workspace` targets the focused window), BC19 (pin-toggle off), BC24
(bar non-blocking under grabs), BC25 (focus <= 1 round-trip), BC26 (capacity
refusal). Most need a new action/binding or live X timing; revisit when such
a binding exists.

Determinism notes: scenarios assert *shape* (rects, stacking, parked
positions, border widths, EWMH flags) rather than pixel content. The
normalizer maps window ids to tokens by first appearance, so creation order
must stay deterministic; keep spawns ordered inside scenario scripts. Do NOT
add a scenario whose `dump` captures two or more parked windows with identical
geometry (`-30000`) that live on *different* workspaces — their X-stacking
order is nondeterministic and will make `--compare` flaky (see S23, reverted).
