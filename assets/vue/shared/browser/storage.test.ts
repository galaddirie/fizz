import { describe, expect, it } from 'vitest';

import {
  readStorageBoolean,
  readStorageString,
  removeStorageItem,
  writeStorageBoolean,
  writeStorageString,
} from './storage';

describe('storage helpers', () => {
  it('reads and writes strings safely', () => {
    writeStorageString('fizz:test:key', 'value');

    expect(readStorageString('fizz:test:key')).toBe('value');

    removeStorageItem('fizz:test:key');

    expect(readStorageString('fizz:test:key')).toBeNull();
  });

  it('reads and writes booleans with fallbacks', () => {
    removeStorageItem('fizz:test:bool');

    expect(readStorageBoolean('fizz:test:bool', true)).toBe(true);

    writeStorageBoolean('fizz:test:bool', false);
    expect(readStorageBoolean('fizz:test:bool', true)).toBe(false);
  });
});

