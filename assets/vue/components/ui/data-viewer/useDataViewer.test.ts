import { describe, expect, it, vi } from 'vitest';

import { useDataViewer } from './useDataViewer';

describe('useDataViewer', () => {
  it('tracks expansion state for nested values', () => {
    const viewer = useDataViewer();

    viewer.toggleExpanded('$.profile');
    viewer.expandAll({
      profile: {
        name: 'Ada',
        roles: ['admin'],
      },
    });

    expect(viewer.expandedPaths.value.has('$.profile')).toBe(true);
    expect(viewer.expandedPaths.value.has('$.profile.roles')).toBe(true);

    viewer.collapseAll();

    expect(viewer.expandedPaths.value.size).toBe(0);
  });

  it('expands to a given depth and resets copied state after copying', () => {
    vi.useFakeTimers();
    const writeText = vi.fn();
    Object.defineProperty(window.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });

    const viewer = useDataViewer('json');
    viewer.expandToDepth(
      {
        profile: {
          name: 'Ada',
          roles: ['admin'],
        },
      },
      1,
    );

    expect(viewer.viewMode.value).toBe('json');
    expect(viewer.expandedPaths.value.has('$')).toBe(true);
    expect(viewer.expandedPaths.value.has('$.profile')).toBe(false);

    viewer.copyToClipboard('$.profile.name');
    expect(writeText).toHaveBeenCalledWith('$.profile.name');
    expect(viewer.copiedPath.value).toBe('$.profile.name');

    vi.advanceTimersByTime(1500);

    expect(viewer.copiedPath.value).toBeNull();
    vi.useRealTimers();
  });
});
