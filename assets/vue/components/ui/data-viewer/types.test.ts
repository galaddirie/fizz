import { describe, expect, it } from 'vitest';

import {
  buildLiquidPath,
  buildTreeNodes,
  formatTreeValue,
  getCollapsedPreview,
  getDataType,
  getTypeLabel,
} from './types';

describe('data viewer types helpers', () => {
  it('derives data types and labels', () => {
    expect(getDataType(null)).toBe('null');
    expect(getDataType(undefined)).toBe('undefined');
    expect(getDataType(['a'])).toBe('array');
    expect(getTypeLabel(['a', 'b'])).toBe('Array[2]');
    expect(getTypeLabel({ first: 1, second: 2 })).toBe('Object{2}');
  });

  it('builds liquid paths and tree nodes for objects and arrays', () => {
    expect(buildLiquidPath('steps.user', ['profile', 'display name', 0])).toBe(
      '{{ steps.user.profile["display name"][0] }}',
    );

    expect(
      buildTreeNodes(
        {
          profile: { name: 'Ada' },
          tags: ['admin'],
        },
        '$',
        [],
      ),
    ).toEqual([
      {
        key: 'profile',
        value: { name: 'Ada' },
        type: 'object',
        path: '$.profile',
        segments: ['profile'],
        isExpandable: true,
        childCount: 1,
      },
      {
        key: 'tags',
        value: ['admin'],
        type: 'array',
        path: '$.tags',
        segments: ['tags'],
        isExpandable: true,
        childCount: 1,
      },
    ]);
  });

  it('formats values and collapsed previews for compact display', () => {
    expect(formatTreeValue('hello', 'string')).toBe('"hello"');
    expect(formatTreeValue(true, 'boolean')).toBe('true');
    expect(getCollapsedPreview(['one', 'two'], 'array')).toBe('["one", "two"]');
    expect(getCollapsedPreview({ a: 1, b: 2, c: 3, d: 4 }, 'object')).toBe(
      '{ a, b, c, … }',
    );
  });
});
