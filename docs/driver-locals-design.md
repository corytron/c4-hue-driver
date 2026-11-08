# The bridge driver's local-variable budget (#373)

Contract for issue #373, part of 1.3 "Kerri" (#398). The agents of this
branch build against this text; the coordinator integrates.

## 1. The problem

Lua 5.1 compiles a function only while it has at most **200 active local
variables** (`LUAI_MAXVARS`) and at most **60 upvalues** (`LUAI_MAXUPVALUES`).
Each driver file's main chunk is a function. On `main` at b414a26, `luac5.1
-p -l -l src/hue_bridge/driver.lua` lists **199** locals for the main chunk;
the other drivers list 79 (light), 123 (motion) and 109 (scene). One more
file-level local in the bridge driver and it stops compiling: lint, every
spec and the build fail loudly, but every feature of 1.3 is blocked.

## 2. What changes

**A. Move whole groups out of `src/hue_bridge/driver.lua`** into modules
under `src/hue_bridge/bridge/`, wired the way the existing modules are: a
`require` at the top, a `new(ctx)` (or plain functions taking what they
need), with the driver passing callbacks and state in a context table rather
than the module reaching back into the driver.

- **Target:** the bridge driver's main chunk at **150 locals or fewer**
  (measured as in section 1), leaving room for 1.3 and later work.
- **Candidates**, from the issue: the Bridges Found list and the pairing
  window; the away and outage handling (the `away`, `outage` and `bridges`
  tables); the housekeeping wiring. Any other self-contained group may move
  too, as long as the result reads better, not just counts lower.
- **Behaviour unchanged.** The new modules do exactly what the moved code did:
  the same texts, the same timers and the same order of events. Every
  existing spec keeps passing. A spec that reached into a moved function
  through the driver may be rewritten to reach it through its new module, but
  its assertions stay the same.
- **Each new module gets its own spec** (`tests/hue_bridge/<module>_spec.lua`,
  in the style of the others), covering what the moved code does on its own.
- **No new globals.** No Snap One code, no `require` outside the package.

**B. A check that keeps it there:** `luac5.1 -p -l -l` on every Lua file
under `src/`, failing when any function (main chunks included) has **more
than 180 locals** or **more than 50 upvalues**. The failure message names the
file, the function's line, the count, the limit and this document. It runs in
`tools/check.sh` as a new check named `lua-limits`, in CI's "Lint and test
(Lua 5.1)" job (that job has `luac5.1`). It has its own tests, which run in
the job that runs the other tooling tests.

## 3. Who owns which file

| Owner | Files |
| --- | --- |
| Agent **R** (refactor) | `src/hue_bridge/driver.lua`; new `src/hue_bridge/bridge/*.lua` modules; their new specs under `tests/hue_bridge/`; edits to existing specs that reached into moved code |
| Agent **T** (tooling) | the new check script under `tools/` and its tests under `tools/tests/`; `tools/check.sh`; `.github/workflows/ci.yml` (only the "Lint and test (Lua 5.1)" job's `--only` list) |
| Coordinator | this document, `CLAUDE.md`, `docs/design.md`, `CHANGELOG.md`, `docs/status.md`, git |

## 4. Done

- R: `luac5.1 -p -l -l src/hue_bridge/driver.lua` shows at most 150 locals for
  the main chunk; `luacheck src tests tools` is clean; `busted tests` passes.
- T: the new check passes on the tree after R's work, fails with the message
  above when a function has too many locals or upvalues (shown by its tests),
  and `tools/check.sh --only lua-limits` runs it.
- Together: `tools/check.sh` and `tools/build.sh` pass in this worktree.
