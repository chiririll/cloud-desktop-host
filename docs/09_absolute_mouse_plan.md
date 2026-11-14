# Absolute mouse plan

Status: phase 1 and 2 implemented (B1). V1 confirmed in a container on 2026-11-14; remaining checks reported fine by the user, not individually recorded. Based on a read of `src/input.cpp`, `src/protocols.cpp`, `src/dbus_input.cpp`, the bundled wlroots 0.20.2 and KWin master (`src/backends/wayland/wayland_backend.cpp`, `src/backends/wayland/wayland_output.cpp`, `src/pointer_input.cpp`) as of 2026-11-14. Items marked **unverified** are conclusions from source reading that still have to be confirmed in a container.

## Symptom

With Moonlight's "Optimize mouse for remote desktop" enabled, the cursor is sometimes confined to a region near one corner of the screen, usually bottom-left. Dragging to the left edge frees the X axis, dragging to the bottom edge frees the Y axis, after which everything is normal until it happens again.

## Cause

In that Moonlight mode, Sunshine emits positions through its absolute uinput device. libinput reports them as `LIBINPUT_EVENT_POINTER_MOTION_ABSOLUTE` and CDH handles them in `handle_pointer_motion_abs` (`src/input.cpp`).

KWin holds a pointer lock in CDH for the whole desktop session (CDH sends a virtual Right Ctrl after the desktop surface maps, `src/xdg.cpp`). While the lock is active, CDH assumes KWin ignores absolute motion, so it converts each absolute position into a delta from its own last position and sends it as `zwp_relative_pointer_v1.relative_motion`. KWin adds that delta to its own cursor position. Two independent positions now exist, CDH's `cursor_x/cursor_y` and KWin's `m_pos`, with no feedback from KWin to CDH.

The two are aligned once per lock by a trick: a delta of `(-2*width, -2*height)` so that KWin clamps its cursor to `(0,0)`, then a delta of `(x, y)` (`src/input.cpp`, the block guarded by `abs_synced`). After that, any event that moves one side but not the other leaves a constant offset. KWin clamps its cursor to the screen on each axis separately, so dragging to an edge removes the offset on that axis. That is the "fixes itself at the edges" behaviour. A corner-sized region means the offset is close to a full screen.

Ways the offset appears, found in code:

| # | Trigger | Why it desyncs |
|---|---|---|
| T1 | Mouse moving while KWin creates the lock | KWin creates its `zwp_relative_pointer_v1` only after it receives `locked` (one round trip). `wlr_relative_pointer_manager_v1_send_relative_motion` silently sends nothing when the client has no relative pointer or no pointer focus (`types/wlr_relative_pointer_v1.c`). The one-shot sync is lost and `abs_synced` is set anyway. Every Right Ctrl press toggles the lock in KWin's nested backend, so this is not a start-up-only event. |
| T2 | `SetOutputMode` | `abs_synced` is cleared at once (`src/dbus_input.cpp`), but KWin resizes its output later and throttles configures. A sync performed before the resize is clamped against the old geometry. |
| T3 | KWin moves its cursor on its own | Warp to the output centre when the cursor falls outside after a resize; frozen position while an application inside KWin holds a pointer lock; XWarpPointer and `wp_pointer_warp_v1` requests; screen-edge push-back. CDH keeps following Moonlight meanwhile. |

## Key finding

The assumption behind the delta conversion is wrong. In KWin's nested Wayland backend:

- the handler for host `wl_pointer.motion` emits `pointerMotionAbsolute` with no condition on the lock state (`wayland_backend.cpp`, `WaylandInputDevice(Pointer*)` constructor);
- `PointerInputRedirection::processMotionAbsolute` has no guard for the backend lock; it sets `m_pos` to the given point (`pointer_input.cpp`);
- the only lock-related read in the pointer path is `m_locked`, which is a pointer constraint held by a client *inside* KWin, not the host lock;
- wlroots does not suppress `wlr_seat_pointer_notify_motion` for a locked pointer. Constraint enforcement is the compositor's job and CDH never suppresses it.

So while locked, CDH can send ordinary absolute motion and KWin will place its cursor exactly there. With no second position to keep in step, nothing can drift. **Unverified** on the KWin build inside the container; the behaviour above is from KWin master. The nested backend has had the same structure since Plasma 6.0, but this must be checked first (see Verification, V1).

## Design decision

Options considered:

| Option | Content | Verdict |
|---|---|---|
| A | Make the one-shot sync robust: re-arm it from `new_relative_pointer`, after KWin commits the new size, and after idle gaps | Rejected. Still open-loop, still two positions, still breaks on T3. |
| B | Send absolute motion for the absolute device regardless of lock state; delete the sync and the delta conversion | **Chosen.** Smallest change, removes the root cause. |
| C | Drop the Right Ctrl lock: CDH renders KWin's cursor itself (`request_set_cursor`), KWin runs unlocked | Deferred. The relative device still needs the lock so games get unbounded deltas; unlocked nested KWin derives deltas from clamped positions and the view stops at screen edges. Net gain is cursor ownership and removing the Right Ctrl toggle side effect. Worth a separate plan. |

Within B, one sub-choice. When a client inside KWin holds a pointer lock (a game under Moonlight's desktop mode), KWin derives zero delta from absolute motion, so the game sees no mouse movement.

- B1: absolute only. Simplest. Games need Moonlight's game mouse mode anyway, which already uses the relative device.
- B2: send `relative_motion(dx, dy)` first and `wl_pointer.motion(x, y)` second in the same frame. KWin applies events in order: the delta reaches a pointer-locked client, then the absolute motion makes the position exact. When KWin's `m_locked` is set, `updatePosition` ignores both and the position stays frozen, which is the intended behaviour. Costs one extra event per sample at up to 1000 Hz and two `motion` events to the focused client per sample.

Start with B1. B2 is a three-line addition if desktop-mode games turn out to matter.

## Changes

| Phase | File | Change |
|---|---|---|
| 1 | `src/input.cpp` `handle_pointer_motion_abs` | Remove the `abs_synced` block and the `else if (relative_pointer_mgr && ...)` branch. Always: ensure pointer focus (`wlr_seat_pointer_notify_enter` on `desktop_surface` when nothing is focused), then `wlr_seat_pointer_notify_motion(seat, time, x, y)`, set `cursor_x/cursor_y`, `notify_frame`, schedule a frame. Drop the now-unused `dx`/`dy`. Rewrite the comment: KWin accepts absolute motion while locked, so no conversion is needed. |
| 1 | `src/server.h` | Delete `abs_synced`. |
| 1 | `src/protocols.cpp` `new_pointer_constraint` | Delete `server->abs_synced = false;`. |
| 1 | `src/dbus_input.cpp` `method_set_output_mode` | Delete `server->abs_synced = false;` and its comment. |
| 1 | `src/input.cpp` `handle_pointer_motion` | No functional change. Confirm the relative path still only sends `wl_pointer.motion` in FREE mode and `relative_motion` always; KWin has no relative pointer while unlocked, so there is no double movement. |
| 2 | `docs/Архитектура cloud-desktop-host (CDH).md` section 9.2, `docs/APP_ARCHITECTURE.md` lines 188-189 and 281 | Rewrite the FREE/LOCKED table: LOCKED changes how the *relative* device is forwarded; the absolute device is always forwarded as absolute motion. Add one sentence on why (KWin's nested backend does not drop absolute motion under lock). |
| 2 | `docs/Архитектура cloud-desktop-host (CDH).md` section 9.1 table | `POINTER_MOTION_ABSOLUTE → pointer_notify_motion` is already what the table says; no change beyond section 9.2. |
| 3 (optional) | `src/input.cpp` | B2: send `relative_motion(dx, dy, dx, dy)` before the absolute motion when `has_active_constraint`. Only if V5 shows a need. |

Expected diff size for phase 1: about 25 lines removed, 5 added.

## Verification

Run in the container with KWin in Desktop mode. V1 decides whether the plan is valid; do it before writing any code.

| # | Check | How | Expected |
|---|---|---|---|
| V1 | KWin honours absolute motion while locked | Temporary patch: in `handle_pointer_motion_abs` send `wlr_seat_pointer_notify_motion` unconditionally and comment out the relative branch. Connect with Moonlight in desktop mouse mode. | Cursor follows the client pointer 1:1 from the first event, including right after connect. If it does not move at all, the plan is invalid; fall back to option A or C. |
| V2 | No corner confinement | Repeat the triggers: connect while moving the mouse, press Right Ctrl twice while moving, switch stream resolution between two Moonlight clients, run an application that locks the pointer and quit it. | Cursor is never offset. |
| V3 | Game mouse mode unchanged | Moonlight with desktop mouse mode off, FPS game under KWin. | Unbounded turning, no change from before. |
| V4 | Right Ctrl behaviour | Press Right Ctrl once in desktop mouse mode. | KWin unlocks (cursor may stop being drawn into the stream, as before). Pointer still follows. Press again: lock returns, cursor still exact with no edge dragging needed. |
| V5 | Pointer-locked application in desktop mouse mode | Browser pointer-lock demo or a game, with desktop mouse mode on. | B1: application receives no motion; this was already unusable in that mode because the client cursor hits the Moonlight window edge. Decide whether B2 is wanted. |
| V6 | Debug HUD | `debug_ui.cpp` reads `has_active_constraint` only; no reference to `abs_synced`. | Builds and shows LOCKED state as before. |
| V7 | Steam GamepadUI and Deck modes | `--no-auto-lock` and gamescope client. | Not affected: the lock is never created there, so FREE path runs, unchanged. |

## Risks

| Risk | Mitigation |
|---|---|
| KWin version in the container drops absolute motion under lock | V1 before coding. Plasma 6.0 to 6.5 nested backend has no such check in the fetched source; older Plasma 5 is not a target. |
| Protocol purists: sending `wl_pointer.motion` to a locked pointer violates `zwp_pointer_constraints_v1` wording | KWin is the only client that locks here. Document the reliance in the architecture doc. Option C is the clean long-term route. |
| Pointer focus lost while locked | The FREE-mode enter fallback is moved out of the `!has_active_constraint` branch, so focus is restored on the next event in either mode. |

## Later

- Option C: CDH-side cursor rendering and removal of the Right Ctrl lock hack for desktop mode. Needs a lock only when the relative device is in use, which CDH can detect per libinput event; worth its own plan.
- The relative device in FREE mode sends `wl_pointer.motion` and `relative_motion` for the same sample. Harmless today because KWin has no relative pointer while unlocked, but it would double-move with any client that binds a relative pointer without locking. Consider sending `relative_motion` only when `has_active_constraint` is set.
