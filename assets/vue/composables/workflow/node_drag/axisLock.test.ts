import { describe, expect, it } from 'vitest';

import { constrainPosition, resolveAxisLock } from './axisLock';
import type { DragSession } from './types';

const createSession = (overrides: Partial<DragSession> = {}): DragSession => ({
  startPositions: new Map(),
  startAbsolutePositions: new Map(),
  lastPositions: new Map(),
  startGroupBounds: new Map(),
  startStepPositions: new Map(),
  startGroupByStepId: new Map(),
  anchorMouse: { x: 0, y: 0 },
  axisLock: null,
  lockAbsDelta: null,
  recentSamples: [],
  ...overrides,
});

describe('node drag axis lock', () => {
  it('establishes an axis lock from dominant movement', () => {
    const session = createSession();

    expect(resolveAxisLock(session, true, { x: 12, y: 2 }, 100)).toBe('x');
    expect(session.axisLock).toBe('x');
    expect(session.lockAbsDelta).toEqual({ x: 12, y: 2 });
  });

  it('switches axes when counter movement decisively overtakes the lock', () => {
    const session = createSession();

    expect(resolveAxisLock(session, true, { x: 12, y: 2 }, 100)).toBe('x');
    expect(resolveAxisLock(session, true, { x: 18, y: 4 }, 170)).toBe('x');
    expect(resolveAxisLock(session, true, { x: 20, y: 22 }, 220)).toBe('y');
    expect(session.axisLock).toBe('y');
    expect(session.lockAbsDelta).toEqual({ x: 20, y: 22 });
  });

  it('clears lock state when the modifier is released', () => {
    const session = createSession({
      axisLock: 'x',
      lockAbsDelta: { x: 12, y: 2 },
      recentSamples: [{ timestamp: 100, position: { x: 12, y: 2 } }],
    });

    expect(resolveAxisLock(session, false, { x: 18, y: 3 }, 240)).toBeNull();
    expect(session.axisLock).toBeNull();
    expect(session.lockAbsDelta).toBeNull();
    expect(session.recentSamples).toEqual([]);
  });

  it('constrains motion and snapping against the locked axis', () => {
    expect(
      constrainPosition(
        { x: 13, y: 17 },
        { x: 0, y: 0 },
        { x: 15, y: 21 },
        'x',
        true,
        24
      )
    ).toEqual({ x: 24, y: 17 });

    expect(
      constrainPosition(
        { x: 13, y: 17 },
        { x: 0, y: 0 },
        { x: 15, y: 21 },
        null,
        true,
        24
      )
    ).toEqual({ x: 24, y: 48 });
  });
});
