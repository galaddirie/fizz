import { describe, expect, it } from 'vitest';

import {
  AXIS_LOCK_THRESHOLD,
  CURSOR_THROTTLE_MS,
  DEFAULT_GROUP_DIMENSIONS,
  DEFAULT_NODE_DIMENSIONS,
  DEFAULT_VIEWPORT,
  DOUBLE_CLICK_DELAY_MS,
  EDGE_LABEL_DIMENSIONS,
  EDGE_LABEL_GAP,
  EDGE_LABEL_HALF_HEIGHT,
  EDGE_LABEL_HALF_WIDTH,
  EDGE_LABEL_PADDING,
  EDGE_LABEL_POSITION,
  GRID_SIZE,
  GROUP_NAME_FONT_SIZE_MAX,
  GROUP_NAME_FONT_SIZE_MIN,
} from './layout';

describe('layout constants', () => {
  it('keeps the editor interaction constants in sane ranges', () => {
    expect(DEFAULT_VIEWPORT).toEqual({ zoom: 1.2, x: 100, y: 50 });
    expect(DOUBLE_CLICK_DELAY_MS).toBeGreaterThan(CURSOR_THROTTLE_MS);
    expect(GRID_SIZE).toBeGreaterThan(AXIS_LOCK_THRESHOLD);
    expect(DEFAULT_NODE_DIMENSIONS.width).toBeGreaterThan(0);
    expect(DEFAULT_GROUP_DIMENSIONS.height).toBeGreaterThan(DEFAULT_NODE_DIMENSIONS.height);
    expect(GROUP_NAME_FONT_SIZE_MAX).toBeGreaterThan(GROUP_NAME_FONT_SIZE_MIN);
  });

  it('derives edge label geometry from the shared constants', () => {
    expect(EDGE_LABEL_HALF_WIDTH).toBe(
      EDGE_LABEL_DIMENSIONS.width / 2 + EDGE_LABEL_PADDING,
    );
    expect(EDGE_LABEL_HALF_HEIGHT).toBe(
      EDGE_LABEL_DIMENSIONS.height / 2 + EDGE_LABEL_PADDING,
    );
    expect(EDGE_LABEL_GAP).toBe(
      Math.ceil((EDGE_LABEL_HALF_WIDTH / (1 - EDGE_LABEL_POSITION)) * 2),
    );
  });
});
