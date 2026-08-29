You are analyzing ONE subsystem of "hana", a Zig X11 tiling window manager
at /home/akai/eudaimonia/hana. Your assignment: subsystem [N] as defined in
docs/subsystems.md. Read that file first, including "Ground rules" and
"Cross-subsystem contracts" - they bind you.

Scope discipline: you may read ANY file for context, but propose changes
ONLY within your assigned files. You are READ-ONLY - do not edit anything.

Analyze along four axes:
1. Performance/resources: allocations, redundant X round trips, repeated
   computation, cache correctness, hot paths.
2. Complexity: dead code, duplication, reducible state machines, tangled
   error paths.
3. Readability/structure: naming, misleading or stale comments, function
   length/cohesion, section organization.
4. Robustness gaps: unchecked invariants, integer/overflow edge cases,
   silently swallowed errors.

Method requirements:
- Verify reachability before claiming dead code: textual grep misses
  comptime/string-keyed dispatch (plugin tables, action enum switches).
  Use the compiler or read dispatch sites.
- For every cache, flag, or lookup table: determine whether it encodes
  BEHAVIOR or MECHANISM before proposing removal. Two recent deletions
  overshot 5x because contract hid inside mechanism; state explicitly
  which one each target is, with evidence.
- Quote the code you are judging. No vague findings.

Output format - numbered findings, each with:
- Anchor: file:line
- Axis (1-4) and category
- Evidence: quoted code + concrete consequence
- Proposal: specific change, not a direction
- Risk: low/medium/high + specific failure mode if wrong
- Gate: zig build test (107/107) | dev/scripts/check-layers.sh |
  dev/harness run-scenario --compare (21/21) | "none - needs new
  coverage" (say what coverage)
- Estimate: LoC delta and/or perf effect, labeled guess vs measured

End with two sections: "Checked and sound" (investigated, justified, do
not re-analyze) and "Questions" (ambiguities you refuse to guess about).

Hard constraints: behavior is frozen (harness goldens are the contract);
no new dependencies; no feature removal; comments are load-bearing - never strip them, only correct them; file splits aiding human navigation
are intentional - never propose merging files for its own sake.
