# ISSUE-003: Other Users' Cursors Not Tracked in Collaborative Editing

**Priority:** Medium
**Component:** Workflow Editor / Presence / CollaborativeCursors
**Status:** Open

## Summary

When multiple users join a workflow editing session, their presence (avatars/names) is visible, but their cursor positions are not tracked or displayed on the canvas.

## Current Behavior

The server-side infrastructure for cursor tracking exists:

- `editor.ex:103-104` handles `mouse_move` events and calls `update_presence_cursor/2`
- `update_presence_cursor/2` (`editor.ex:643-655`) updates Phoenix Presence with `cursor: %{x, y}` data, throttled at 60ms
- `cursor_from_payload/1` (`editor.ex:1477-1484`) extracts x/y coordinates from the event payload
- `initial_presence_meta/1` (`editor.ex:1440-1450`) sets `cursor: nil` initially
- `CollaborativeCursors.vue` renders cursor indicators for other users based on presence data

The issue is likely on the **client side**: the Vue editor component is not emitting `mouse_move` events to the LiveView, or the presence data containing cursor positions is not being passed to the `CollaborativeCursors` component correctly.

## Investigation Areas

1. **Vue component not pushing mouse_move events** — Check if the canvas/editor Vue component has a `mousemove` listener that calls `pushEvent("mouse_move", {x, y})` with canvas-relative coordinates (accounting for zoom/pan).

2. **Presence data not reaching CollaborativeCursors.vue** — The `presences` assign is updated on `presence_diff` (`editor.ex:234-238`) via `presence_entries/1`. Verify the `presences` prop is passed to the Vue component and that `CollaborativeCursors.vue` receives it reactively.

3. **Coordinate space mismatch** — Cursor positions must be in canvas/world coordinates, not screen coordinates. If the editor uses pan/zoom, the mouse position needs to be transformed before sending and after receiving.

4. **Throttling too aggressive** — The 60ms throttle on `update_presence_cursor` may be fine, but if the client is also throttling, the effective rate may be too low for smooth cursor display.

## Relevant Files

- `lib/fizz_web/live/workflows_live/editor.ex` — `update_presence_cursor/2` (line 643), `initial_presence_meta/1` (line 1440), `presence_entries/1`
- `assets/vue/components/flow/CollaborativeCursors.vue` — Renders other users' cursors
- Main editor Vue component (likely in `assets/vue/components/flow/`) — Should emit `mouse_move` events

## Steps to Reproduce

1. User A opens a workflow editor
2. User B opens the same workflow in a different browser
3. Both users can see each other in the presence list
4. Neither user can see the other's cursor on the canvas

## Expected Behavior

Each user's cursor position should be visible to all other connected users as a colored cursor indicator with their name, updating smoothly as they move their mouse over the canvas.

## Acceptance Criteria

- [ ] Mouse movement on the canvas emits `mouse_move` events with canvas-space coordinates
- [ ] Presence data with cursor positions is passed to CollaborativeCursors.vue
- [ ] Other users' cursors render at the correct position, accounting for zoom/pan
- [ ] Cursor updates are smooth (sub-100ms latency perceived)
- [ ] Cursors disappear when a user leaves or goes idle
