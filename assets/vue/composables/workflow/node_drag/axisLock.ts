import type { XYPosition } from '@vue-flow/core';

import { AXIS_LOCK_THRESHOLD } from '@/constants/layout';

import type { DragAxis, DragSession } from './types';

const INTENT_WINDOW_MS = 110;
const AXIS_ESTABLISH_DEADZONE = AXIS_LOCK_THRESHOLD;
const AXIS_ESTABLISH_RECENT_MIN = 3;
const AXIS_ESTABLISH_RECENT_RATIO = 1.2;
const AXIS_ESTABLISH_OVERALL_RATIO = 1.1;
const AXIS_SWITCH_RECENT_MIN = 3;
const AXIS_SWITCH_RECENT_RATIO = 1.45;
const AXIS_SWITCH_BASE_COUNTER = 8;
const AXIS_SWITCH_COUNTER_SLOPE = 0.12;

export const snapValue = (value: number, grid: number) => grid * Math.round(value / grid);

export const dominantAxisFromMagnitude = (
  magnitude: XYPosition,
  ratioThreshold: number,
  majorThreshold: number,
  totalThreshold = 0
): DragAxis | null => {
  const absX = Math.abs(magnitude.x);
  const absY = Math.abs(magnitude.y);
  if (Math.max(absX, absY) < majorThreshold) return null;
  if (absX + absY < totalThreshold) return null;

  const major = Math.max(absX, absY);
  const minor = Math.min(absX, absY);
  const ratio = major / Math.max(1, minor);
  if (ratio < ratioThreshold) return null;
  return absX >= absY ? 'x' : 'y';
};

export const toAbsDelta = (from: XYPosition, to: XYPosition): XYPosition => ({
  x: Math.abs(to.x - from.x),
  y: Math.abs(to.y - from.y),
});

export const trackPointerSample = (
  session: DragSession,
  position: XYPosition,
  now = Date.now()
) => {
  session.recentSamples.push({ timestamp: now, position });
  const cutoff = now - INTENT_WINDOW_MS;
  while (session.recentSamples.length > 0 && session.recentSamples[0].timestamp < cutoff) {
    session.recentSamples.shift();
  }
};

export const getRecentDelta = (session: DragSession, currentPosition: XYPosition): XYPosition => {
  const oldest = session.recentSamples[0];
  if (!oldest) {
    return {
      x: currentPosition.x - session.anchorMouse.x,
      y: currentPosition.y - session.anchorMouse.y,
    };
  }

  return {
    x: currentPosition.x - oldest.position.x,
    y: currentPosition.y - oldest.position.y,
  };
};

export const resolveAxisLock = (
  session: DragSession,
  shiftPressed: boolean,
  flowPosition: XYPosition,
  now = Date.now()
) => {
  if (!shiftPressed) {
    session.axisLock = null;
    session.lockAbsDelta = null;
    session.recentSamples = [];
    return null;
  }

  trackPointerSample(session, flowPosition, now);

  const overallAbs = toAbsDelta(session.anchorMouse, flowPosition);
  const recentDelta = getRecentDelta(session, flowPosition);
  const recentAbs = {
    x: Math.abs(recentDelta.x),
    y: Math.abs(recentDelta.y),
  };

  const overallAxis = dominantAxisFromMagnitude(
    overallAbs,
    AXIS_ESTABLISH_OVERALL_RATIO,
    AXIS_LOCK_THRESHOLD,
    AXIS_ESTABLISH_DEADZONE
  );
  const recentAxis = dominantAxisFromMagnitude(
    recentAbs,
    AXIS_ESTABLISH_RECENT_RATIO,
    AXIS_ESTABLISH_RECENT_MIN,
    AXIS_ESTABLISH_RECENT_MIN
  );

  if (!session.axisLock) {
    if (overallAbs.x + overallAbs.y < AXIS_ESTABLISH_DEADZONE) {
      return null;
    }

    const canEstablishFromBoth =
      overallAxis !== null && recentAxis !== null && overallAxis === recentAxis;
    const overallLeadAxis: DragAxis = overallAbs.x >= overallAbs.y ? 'x' : 'y';
    const canEstablishFromRecentOnly =
      recentAxis !== null && overallAxis === null && recentAxis === overallLeadAxis;
    const canEstablishFromOverallOnly =
      overallAxis !== null &&
      recentAxis === null &&
      Math.max(recentAbs.x, recentAbs.y) < AXIS_ESTABLISH_RECENT_MIN;

    if (canEstablishFromBoth || canEstablishFromRecentOnly || canEstablishFromOverallOnly) {
      session.axisLock = overallAxis ?? recentAxis;
      session.lockAbsDelta = { ...overallAbs };
    }

    return session.axisLock;
  }

  const currentAxis = session.axisLock;
  const oppositeAxis: DragAxis = currentAxis === 'x' ? 'y' : 'x';
  const recentSwitchAxis = dominantAxisFromMagnitude(
    recentAbs,
    AXIS_SWITCH_RECENT_RATIO,
    AXIS_SWITCH_RECENT_MIN,
    AXIS_SWITCH_RECENT_MIN
  );
  if (recentSwitchAxis !== oppositeAxis) {
    return session.axisLock;
  }

  const lockAbs = session.lockAbsDelta ?? overallAbs;
  const primaryCommit =
    currentAxis === 'x'
      ? Math.max(0, overallAbs.x - lockAbs.x)
      : Math.max(0, overallAbs.y - lockAbs.y);
  const counterMovement =
    currentAxis === 'x'
      ? Math.max(0, overallAbs.y - lockAbs.y)
      : Math.max(0, overallAbs.x - lockAbs.x);
  const requiredCounterMovement =
    AXIS_SWITCH_BASE_COUNTER + AXIS_SWITCH_COUNTER_SLOPE * primaryCommit;

  if (counterMovement >= requiredCounterMovement) {
    session.axisLock = oppositeAxis;
    session.lockAbsDelta = { ...overallAbs };
  }

  return session.axisLock;
};

export const constrainPosition = (
  anchorNode: XYPosition,
  anchorMouse: XYPosition,
  mouse: XYPosition,
  axisLock: DragAxis | null,
  shouldSnap: boolean,
  gridSize: number
) => {
  const raw = {
    x: anchorNode.x + (mouse.x - anchorMouse.x),
    y: anchorNode.y + (mouse.y - anchorMouse.y),
  };

  let x = raw.x;
  let y = raw.y;

  if (axisLock === 'x') {
    y = anchorNode.y;
  } else if (axisLock === 'y') {
    x = anchorNode.x;
  }

  if (shouldSnap) {
    if (axisLock === 'x') {
      x = snapValue(x, gridSize);
    } else if (axisLock === 'y') {
      y = snapValue(y, gridSize);
    } else {
      x = snapValue(x, gridSize);
      y = snapValue(y, gridSize);
    }
  }

  return { x, y };
};
