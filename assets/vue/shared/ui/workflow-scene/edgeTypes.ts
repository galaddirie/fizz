import { markRaw } from 'vue';
import type { EdgeComponent, EdgeTypesObject } from '@vue-flow/core';

import CustomEdge from '@/components/flow/Edge.vue';

// Vue Flow's EdgeComponent type is stricter than Vue's inferred SFC type here.
// Keep the cast isolated at the library boundary instead of spreading it through feature code.
export const workflowEdgeTypes: EdgeTypesObject = {
  custom: markRaw(CustomEdge) as EdgeComponent,
};
