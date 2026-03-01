export type DataType = 'string' | 'number' | 'boolean' | 'null' | 'array' | 'object' | 'undefined';
export type ViewMode = 'tree' | 'json';

export interface DataViewerProps {
  data: unknown;
  rootPath?: string;
  maxHeight?: string;
  defaultView?: ViewMode;
  showViewToggle?: boolean;
  onCopyPath?: (path: string) => void;
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

export function buildLiquidPath(rootPath: string, segments: (string | number)[]): string {
  let path = rootPath;
  for (const seg of segments) {
    if (typeof seg === 'number') {
      path += `[${seg}]`;
    } else if (/^[a-zA-Z_][a-zA-Z0-9_]*$/.test(seg)) {
      path += `.${seg}`;
    } else {
      path += `["${seg}"]`;
    }
  }
  return `{{ ${path} }}`;
}

export interface TreeNode {
  key: string | number;
  value: unknown;
  type: DataType;
  path: string;
  segments: (string | number)[];
  isExpandable: boolean;
  childCount: number;
}

export function buildTreeNodes(value: unknown, pathPrefix: string, segments: (string | number)[]): TreeNode[] {
  if (value === null || value === undefined) return [];
  if (typeof value !== 'object') return [];

  if (Array.isArray(value)) {
    return value.map((item, i) => ({
      key: i,
      value: item,
      type: getDataType(item),
      path: `${pathPrefix}[${i}]`,
      segments: [...segments, i],
      isExpandable: item !== null && typeof item === 'object',
      childCount: item && typeof item === 'object'
        ? (Array.isArray(item) ? item.length : Object.keys(item).length)
        : 0,
    }));
  }

  return Object.entries(value).map(([key, val]) => ({
    key,
    value: val,
    type: getDataType(val),
    path: `${pathPrefix}.${key}`,
    segments: [...segments, key],
    isExpandable: val !== null && typeof val === 'object',
    childCount: val && typeof val === 'object'
      ? (Array.isArray(val) ? val.length : Object.keys(val).length)
      : 0,
  }));
}

const MAX_STRING_DISPLAY = 120;

export function formatTreeValue(value: unknown, type: DataType): string {
  if (type === 'string') {
    const str = value as string;
    if (str.length > MAX_STRING_DISPLAY) {
      return `"${str.slice(0, MAX_STRING_DISPLAY)}…"`;
    }
    return `"${str}"`;
  }
  if (type === 'null') return 'null';
  if (type === 'undefined') return 'undefined';
  if (type === 'boolean') return String(value);
  if (type === 'number') return String(value);
  return '';
}

export function getCollapsedPreview(value: unknown, type: DataType): string {
  if (type === 'array') {
    const arr = value as unknown[];
    if (arr.length === 0) return '[]';
    if (arr.length <= 3) {
      const items = arr.map(v => {
        if (v === null) return 'null';
        if (typeof v === 'string') return `"${v.length > 20 ? v.slice(0, 20) + '…' : v}"`;
        if (typeof v === 'object') return Array.isArray(v) ? '[…]' : '{…}';
        return String(v);
      });
      return `[${items.join(', ')}]`;
    }
    return `[${arr.length} items]`;
  }
  if (type === 'object') {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj);
    if (keys.length === 0) return '{}';
    if (keys.length <= 3) return `{ ${keys.join(', ')} }`;
    return `{ ${keys.slice(0, 3).join(', ')}, … }`;
  }
  return '';
}

