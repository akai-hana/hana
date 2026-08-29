# hana smoke-test harness

Behavioral verification for the window manager: each scenario boots a private
Xvfb server and a fresh hana instance with a controlled config, drives it with
synthetic input (`xdotool`), and records X-side truth (`xwininfo`, `xprop`)
plus hana's own state dumps. Outputs are normalized (window IDs -> stable
tokens, PIDs/times scrubbed) so runs are diffable.

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

Determinism notes: scenarios assert *shape* (rects, stacking, parked
positions, border widths, EWMH flags) rather than pixel content. The
normalizer maps window ids to tokens by first appearance, so creation order
must stay deterministic; keep spawns ordered inside scenario scripts.
