import { ref, type Ref } from 'vue';
import { type ViewMode } from './types';

export function useDataViewer(data: Ref<unknown>, defaultView: ViewMode = 'tree') {
  const viewMode = ref<ViewMode>(defaultView);
  const expandedPaths = ref<Set<string>>(new Set());
  const copiedPath = ref<string | null>(null);
  let copyTimeout: ReturnType<typeof setTimeout> | null = null;

  function toggleExpanded(path: string) {
    if (expandedPaths.value.has(path)) {
      expandedPaths.value.delete(path);
    } else {
      expandedPaths.value.add(path);
    }
  }

  function expandAll(value: unknown, prefix = '$') {
    if (value && typeof value === 'object') {
      expandedPaths.value.add(prefix);
      if (Array.isArray(value)) {
        value.forEach((item, index) => expandAll(item, `${prefix}[${index}]`));
      } else {
        for (const key of Object.keys(value)) {
          expandAll((value as Record<string, unknown>)[key], `${prefix}.${key}`);
        }
      }
    }
  }

  function collapseAll() {
    expandedPaths.value.clear();
  }

  function expandToDepth(value: unknown, depth: number, prefix = '$', currentDepth = 0) {
    if (currentDepth >= depth || !value || typeof value !== 'object') return;

    expandedPaths.value.add(prefix);

    if (Array.isArray(value)) {
      value.forEach((item, index) => {
        expandToDepth(item, depth, `${prefix}[${index}]`, currentDepth + 1);
      });
    } else {
      for (const key of Object.keys(value)) {
        expandToDepth(
          (value as Record<string, unknown>)[key],
          depth,
          `${prefix}.${key}`,
          currentDepth + 1
        );
      }
    }
  }

  function copyToClipboard(text: string) {
    navigator.clipboard.writeText(text);
    copiedPath.value = text;
    if (copyTimeout) clearTimeout(copyTimeout);
    copyTimeout = setTimeout(() => {
      copiedPath.value = null;
    }, 1500);
  }

  return {
    viewMode,
    expandedPaths,
    copiedPath,
    toggleExpanded,
    expandAll,
    collapseAll,
    expandToDepth,
    copyToClipboard,
  };
}
