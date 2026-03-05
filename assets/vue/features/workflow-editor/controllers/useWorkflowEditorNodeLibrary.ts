import { onBeforeUnmount, onMounted, ref } from 'vue';

import { readStorageString, writeStorageString } from '@/shared/browser/storage';

const NODE_LIBRARY_DEFAULT_WIDTH = 288;
const NODE_LIBRARY_MIN_WIDTH = 240;
const NODE_LIBRARY_MAX_WIDTH = 460;
const CANVAS_MIN_WIDTH = 640;
const NODE_LIBRARY_COLLAPSE_THRESHOLD = 20;
const NODE_LIBRARY_WIDTH_STORAGE_KEY = 'fizz.workflow_editor.node_library_width';
const NODE_LIBRARY_COLLAPSED_STORAGE_KEY = 'fizz.workflow_editor.node_library_collapsed';

export function useWorkflowEditorNodeLibrary() {
  const nodeLibraryWidth = ref(NODE_LIBRARY_DEFAULT_WIDTH);
  const isResizingNodeLibrary = ref(false);
  const isNodeLibraryCollapsed = ref(false);
  const resizeOrigin = ref<{
    x: number;
    width: number;
    startedCollapsed: boolean;
  } | null>(null);

  const clampNodeLibraryWidth = (rawWidth: number) => {
    const viewportLimit =
      typeof window === 'undefined'
        ? NODE_LIBRARY_MAX_WIDTH
        : Math.max(
            NODE_LIBRARY_MIN_WIDTH,
            Math.min(NODE_LIBRARY_MAX_WIDTH, Math.floor(window.innerWidth - CANVAS_MIN_WIDTH))
          );

    return Math.min(viewportLimit, Math.max(NODE_LIBRARY_MIN_WIDTH, rawWidth));
  };

  const saveNodeLibraryWidth = (width: number) => {
    writeStorageString(
      NODE_LIBRARY_WIDTH_STORAGE_KEY,
      String(clampNodeLibraryWidth(width))
    );
  };

  const saveNodeLibraryCollapsed = (collapsed: boolean) => {
    writeStorageString(NODE_LIBRARY_COLLAPSED_STORAGE_KEY, collapsed ? '1' : '0');
  };

  const setNodeLibraryCollapsed = (collapsed: boolean) => {
    isNodeLibraryCollapsed.value = collapsed;
    saveNodeLibraryCollapsed(collapsed);
  };

  const toggleNodeLibraryCollapsed = () => {
    setNodeLibraryCollapsed(!isNodeLibraryCollapsed.value);
  };

  const stopNodeLibraryResize = () => {
    const wasResizing = isResizingNodeLibrary.value;

    isResizingNodeLibrary.value = false;
    resizeOrigin.value = null;

    if (typeof window !== 'undefined') {
      window.removeEventListener('pointermove', handleNodeLibraryResizeMove);
      window.removeEventListener('pointerup', stopNodeLibraryResize);
      window.removeEventListener('pointercancel', stopNodeLibraryResize);
    }

    if (typeof document !== 'undefined') {
      document.body.classList.remove('cursor-col-resize', 'select-none');
    }

    if (wasResizing) {
      saveNodeLibraryWidth(nodeLibraryWidth.value);
      saveNodeLibraryCollapsed(isNodeLibraryCollapsed.value);
    }
  };

  const handleNodeLibraryResizeMove = (event: PointerEvent) => {
    const origin = resizeOrigin.value;
    if (!origin) return;

    const deltaX = event.clientX - origin.x;
    const candidateWidth = origin.width + deltaX;

    if (origin.startedCollapsed) {
      if (candidateWidth >= NODE_LIBRARY_MIN_WIDTH + NODE_LIBRARY_COLLAPSE_THRESHOLD) {
        isNodeLibraryCollapsed.value = false;
        nodeLibraryWidth.value = clampNodeLibraryWidth(candidateWidth);
      } else {
        isNodeLibraryCollapsed.value = true;
      }

      return;
    }

    if (candidateWidth < NODE_LIBRARY_MIN_WIDTH - NODE_LIBRARY_COLLAPSE_THRESHOLD) {
      isNodeLibraryCollapsed.value = true;
      return;
    }

    isNodeLibraryCollapsed.value = false;
    nodeLibraryWidth.value = clampNodeLibraryWidth(candidateWidth);
  };

  const handleNodeLibraryResizeStart = (event: PointerEvent, fromCollapsed = false) => {
    if (event.button !== 0) return;

    event.preventDefault();
    resizeOrigin.value = {
      x: event.clientX,
      width: fromCollapsed ? NODE_LIBRARY_MIN_WIDTH : nodeLibraryWidth.value,
      startedCollapsed: fromCollapsed,
    };
    isResizingNodeLibrary.value = true;

    if (typeof document !== 'undefined') {
      document.body.classList.add('cursor-col-resize', 'select-none');
    }

    if (typeof window !== 'undefined') {
      window.addEventListener('pointermove', handleNodeLibraryResizeMove);
      window.addEventListener('pointerup', stopNodeLibraryResize);
      window.addEventListener('pointercancel', stopNodeLibraryResize);
    }
  };

  const handleEditorResize = () => {
    nodeLibraryWidth.value = clampNodeLibraryWidth(nodeLibraryWidth.value);
  };

  onMounted(() => {
    const storedWidth = Number(readStorageString(NODE_LIBRARY_WIDTH_STORAGE_KEY));
    const storedCollapsed = readStorageString(NODE_LIBRARY_COLLAPSED_STORAGE_KEY) === '1';

    if (Number.isFinite(storedWidth) && storedWidth > 0) {
      nodeLibraryWidth.value = clampNodeLibraryWidth(storedWidth);
    } else {
      nodeLibraryWidth.value = clampNodeLibraryWidth(nodeLibraryWidth.value);
    }

    isNodeLibraryCollapsed.value = storedCollapsed;
    window.addEventListener('resize', handleEditorResize);
  });

  onBeforeUnmount(() => {
    if (typeof window !== 'undefined') {
      window.removeEventListener('resize', handleEditorResize);
    }

    stopNodeLibraryResize();
  });

  return {
    nodeLibraryWidth,
    isNodeLibraryCollapsed,
    handleNodeLibraryResizeStart,
    toggleNodeLibraryCollapsed,
  };
}
