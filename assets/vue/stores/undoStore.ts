import { computed, ref } from 'vue';
import { defineStore } from 'pinia';

export type UndoEntrySummary = {
  id: string;
  label: string | null;
  timestamp?: string | null;
  depth: number;
};

export type UndoState = {
  canUndo: boolean;
  canRedo: boolean;
  undoLabel: string | null;
  redoLabel: string | null;
  undoStack?: UndoEntrySummary[];
  redoStack?: UndoEntrySummary[];
};

export const useUndoStore = defineStore('undo', () => {
  const state = ref<UndoState>({
    canUndo: false,
    canRedo: false,
    undoLabel: null,
    redoLabel: null,
    undoStack: [],
    redoStack: [],
  });

  const isPending = ref(false);

  const canUndo = computed(() => state.value.canUndo && !isPending.value);
  const canRedo = computed(() => state.value.canRedo && !isPending.value);
  const undoTooltip = computed(() =>
    state.value.undoLabel ? `Undo: ${state.value.undoLabel} (⌘Z)` : 'Nothing to undo'
  );
  const redoTooltip = computed(() =>
    state.value.redoLabel ? `Redo: ${state.value.redoLabel} (⌘⇧Z)` : 'Nothing to redo'
  );

  const undo = (sendUndo: () => void) => {
    if (!canUndo.value) return;
    isPending.value = true;
    sendUndo();
  };

  const redo = (sendRedo: () => void) => {
    if (!canRedo.value) return;
    isPending.value = true;
    sendRedo();
  };

  const handleStateUpdate = (payload: UndoState) => {
    state.value = {
      ...payload,
      undoStack: payload.undoStack ?? [],
      redoStack: payload.redoStack ?? [],
    };
    isPending.value = false;
  };

  const handleUndoApplied = () => {
    isPending.value = false;
  };

  const handleUndoConflict = () => {
    isPending.value = false;
  };

  const handleRedoApplied = () => {
    isPending.value = false;
  };

  const handleRedoConflict = () => {
    isPending.value = false;
  };

  return {
    state,
    isPending,
    canUndo,
    canRedo,
    undoTooltip,
    redoTooltip,
    undo,
    redo,
    handleStateUpdate,
    handleUndoApplied,
    handleUndoConflict,
    handleRedoApplied,
    handleRedoConflict,
  };
});
