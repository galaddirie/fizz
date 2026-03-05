import { defineStore } from 'pinia';
import { ref } from 'vue';
import { readStorageBoolean, writeStorageBoolean } from '@/shared/browser/storage';

const SNAP_ENABLED_STORAGE_KEY = 'fizz.workflow_editor.snap_enabled';

export const useClientStore = defineStore('client', () => {
  // Panel state
  const isLibraryOpen = ref(true);
  const isTracePanelExpanded = ref(true);
  const snapEnabled = ref(readStorageBoolean(SNAP_ENABLED_STORAGE_KEY, false));

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

  const setSnapEnabled = (enabled: boolean) => {
    snapEnabled.value = enabled;
    writeStorageBoolean(SNAP_ENABLED_STORAGE_KEY, enabled);
  };

  const toggleSnap = () => {
    setSnapEnabled(!snapEnabled.value);
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
    snapEnabled,
    selectedNodeId,
    isConfigModalOpen,
    contextMenu,
    toggleLibrary,
    toggleTracePanel,
    setSnapEnabled,
    toggleSnap,
    openConfigModal,
    closeConfigModal,
    selectNode,
    showContextMenu,
    hideContextMenu,
  };
});
