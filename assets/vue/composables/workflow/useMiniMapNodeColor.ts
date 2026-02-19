import type { GraphNode } from '@vue-flow/core';

import { DEFAULT_GROUP_COLOR } from '@/constants/layout';
import type { GroupNodeData, WorkflowNodeData } from '@/types/workflow';

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace('#', '');
  const r = parseInt(normalized.slice(0, 2), 16);
  const g = parseInt(normalized.slice(2, 4), 16);
  const b = parseInt(normalized.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

export function useMiniMapNodeColor() {
  const miniMapNodeColor = (node: GraphNode<WorkflowNodeData>) => {
    if (node.type === 'group') {
      const color = (node.data as GroupNodeData | undefined)?.color || DEFAULT_GROUP_COLOR;
      return hexToRgba(color, 0.45);
    }
    return 'color-mix(in oklch, var(--color-base-100) 72%, var(--color-base-content) 28%)';
  };

  return { miniMapNodeColor };
}
