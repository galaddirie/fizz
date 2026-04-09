export type ViewMode = 'tree' | 'json' | 'table';
export type JsonPathSegment = string | number;
export type DataType = 'string' | 'number' | 'boolean' | 'null' | 'array' | 'object' | 'undefined';

export interface DataViewerProps {
  data: unknown;
  rootPath?: string;
  maxHeight?: string;
  defaultView?: ViewMode;
  showViewToggle?: boolean;
  onCopyPath?: (path: string) => void;
}

export interface TreeNode {
  key: string | number;
  value: unknown;
  type: DataType;
  path: string;
  segments: JsonPathSegment[];
  isExpandable: boolean;
  childCount: number;
}

export function getDataType(value: unknown): DataType {
  if (value === null) return 'null';
  if (value === undefined) return 'undefined';
  if (Array.isArray(value)) return 'array';
  return typeof value as DataType;
}

export function getTypeLabel(value: unknown): string {
  const type = getDataType(value);
  if (type === 'array') return `Array[${(value as unknown[]).length}]`;
  if (type === 'object') return `Object{${Object.keys(value as object).length}}`;
  return type;
}

export const typeColors: Record<DataType, { text: string; bg: string }> = {
  string: { text: 'text-emerald-600', bg: 'bg-emerald-500/10' },
  number: { text: 'text-blue-600', bg: 'bg-blue-500/10' },
  boolean: { text: 'text-violet-600', bg: 'bg-violet-500/10' },
  null: { text: 'text-base-content/50', bg: 'bg-base-content/5' },
  undefined: { text: 'text-base-content/50', bg: 'bg-base-content/5' },
  array: { text: 'text-amber-600', bg: 'bg-amber-500/10' },
  object: { text: 'text-slate-600', bg: 'bg-slate-500/10' },
};

export function buildLiquidPath(rootPath: string, segments: JsonPathSegment[]): string {
  let path = rootPath;

  for (const segment of segments) {
    if (typeof segment === 'number') {
      path += `[${segment}]`;
      continue;
    }

    if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(segment)) {
      path += `.${segment}`;
      continue;
    }

    path += `[${JSON.stringify(segment)}]`;
  }

  return `{{ ${path} }}`;
}

export function normalizeJsonPathSegments(value: unknown, path: string[]): JsonPathSegment[] {
  let current = value;

  return path.map(segment => {
    if (Array.isArray(current) && /^\d+$/.test(segment)) {
      const index = Number(segment);
      current = current[index];
      return index;
    }

    if (current && typeof current === 'object') {
      current = (current as Record<string, unknown>)[segment];
    } else {
      current = undefined;
    }

    return segment;
  });
}

export function buildTreeNodes(
  value: unknown,
  pathPrefix: string,
  segments: JsonPathSegment[]
): TreeNode[] {
  if (value === null || value === undefined) return [];
  if (typeof value !== 'object') return [];

  if (Array.isArray(value)) {
    return value.map((item, index) => ({
      key: index,
      value: item,
      type: getDataType(item),
      path: `${pathPrefix}[${index}]`,
      segments: [...segments, index],
      isExpandable: item !== null && typeof item === 'object',
      childCount:
        item && typeof item === 'object'
          ? Array.isArray(item)
            ? item.length
            : Object.keys(item).length
          : 0,
    }));
  }

  return Object.entries(value).map(([key, entryValue]) => ({
    key,
    value: entryValue,
    type: getDataType(entryValue),
    path: `${pathPrefix}.${key}`,
    segments: [...segments, key],
    isExpandable: entryValue !== null && typeof entryValue === 'object',
    childCount:
      entryValue && typeof entryValue === 'object'
        ? Array.isArray(entryValue)
          ? entryValue.length
          : Object.keys(entryValue).length
        : 0,
  }));
}

const MAX_STRING_DISPLAY = 120;

export function formatTreeValue(value: unknown, type: DataType): string {
  if (type === 'string') {
    const stringValue = value as string;
    if (stringValue.length > MAX_STRING_DISPLAY) {
      return `"${stringValue.slice(0, MAX_STRING_DISPLAY)}…"`;
    }
    return `"${stringValue}"`;
  }

  if (type === 'null') return 'null';
  if (type === 'undefined') return 'undefined';
  if (type === 'boolean') return String(value);
  if (type === 'number') return String(value);
  return '';
}

export function getCollapsedPreview(value: unknown, type: DataType): string {
  if (type === 'array') {
    const arrayValue = value as unknown[];
    if (arrayValue.length === 0) return '[]';

    if (arrayValue.length <= 3) {
      const items = arrayValue.map(item => {
        if (item === null) return 'null';
        if (typeof item === 'string') {
          return `"${item.length > 20 ? `${item.slice(0, 20)}…` : item}"`;
        }
        if (typeof item === 'object') return Array.isArray(item) ? '[…]' : '{…}';
        return String(item);
      });

      return `[${items.join(', ')}]`;
    }

    return `[${arrayValue.length} items]`;
  }

  if (type === 'object') {
    const objectValue = value as Record<string, unknown>;
    const keys = Object.keys(objectValue);
    if (keys.length === 0) return '{}';
    if (keys.length <= 3) return `{ ${keys.join(', ')} }`;
    return `{ ${keys.slice(0, 3).join(', ')}, … }`;
  }

  return '';
}

export function formatJsonForClipboard(value: unknown): string {
  if (value === undefined) return 'undefined';
  if (value === null) return 'null';

  const formatted = JSON.stringify(value, null, 2);
  return formatted ?? String(value);
}
