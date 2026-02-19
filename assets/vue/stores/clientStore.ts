import { defineStore } from 'pinia';
import { ref } from 'vue';

export const useClientStore = defineStore('client', () => {
  // Panel state
  const isLibraryOpen = ref(true);
  const isTracePanelExpanded = ref(true);

  // Selection state
  const selectedNodeId = ref<string | null>(null);
  const isConfigModalOpen = ref(false);

  // Context Menu state
  const contextMenu = ref({
    show: false,
    x: 0,
    y: 0,
    targetNodeId: null as string | null,
    targetType: 'pane' as 'node' | 'pane',
  });

  // Actions
  const toggleLibrary = () => {
    isLibraryOpen.value = !isLibraryOpen.value;
  };

  const toggleTracePanel = () => {
    isTracePanelExpanded.value = !isTracePanelExpanded.value;
  };

  const openConfigModal = (nodeId: string) => {
    selectedNodeId.value = nodeId;
    isConfigModalOpen.value = true;
  };

  const closeConfigModal = () => {
    isConfigModalOpen.value = false;
  };

  const selectNode = (nodeId: string | null) => {
    selectedNodeId.value = nodeId;
  };

  const showContextMenu = (
    x: number,
    y: number,
    targetType: 'node' | 'pane',
    targetNodeId: string | null = null
  ) => {
    contextMenu.value = {
      show: true,
      x,
      y,
      targetType,
      targetNodeId,
    };
  };

  const hideContextMenu = () => {
    contextMenu.value.show = false;
  };

  return {
    isLibraryOpen,
    isTracePanelExpanded,
    selectedNodeId,
    isConfigModalOpen,
    contextMenu,
    toggleLibrary,
    toggleTracePanel,
    openConfigModal,
    closeConfigModal,
    selectNode,
    showContextMenu,
    hideContextMenu,
  };
});
