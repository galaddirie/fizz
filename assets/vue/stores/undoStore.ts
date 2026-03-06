import { computed, ref } from "vue";
import { defineStore } from "pinia";

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

export const useUndoStore = defineStore("undo", () => {
  const state = ref<UndoState>({
    canUndo: false,
    canRedo: false,
    undoLabel: null,
    redoLabel: null,
    undoStack: [],
    redoStack: [],
  });

  const isPending = ref(false);
  const transport = ref<{
    requestUndo: () => void;
    requestRedo: () => void;
  } | null>(null);

  const canUndo = computed(() => state.value.canUndo && !isPending.value);
  const canRedo = computed(() => state.value.canRedo && !isPending.value);
  const undoTooltip = computed(() =>
    state.value.undoLabel
      ? `Undo: ${state.value.undoLabel} (⌘Z)`
      : "Nothing to undo"
  );
  const redoTooltip = computed(() =>
    state.value.redoLabel
      ? `Redo: ${state.value.redoLabel} (⌘⇧Z)`
      : "Nothing to redo"
  );

  const configureTransport = (nextTransport: {
    requestUndo: () => void;
    requestRedo: () => void;
  }) => {
    transport.value = nextTransport;
  };

  const requestUndo = () => {
    if (!canUndo.value) return;
    if (!transport.value) return;
    isPending.value = true;
    transport.value.requestUndo();
  };

  const requestRedo = () => {
    if (!canRedo.value) return;
    if (!transport.value) return;
    isPending.value = true;
    transport.value.requestRedo();
  };

  const handleStateUpdate = (payload: UndoState) => {
    state.value = {
      ...payload,
      undoStack: payload.undoStack ?? [],
      redoStack: payload.redoStack ?? [],
    };
    isPending.value = false;
  };

  const resolveUndoRequest = () => {
    isPending.value = false;
  };

  const resolveRedoRequest = () => {
    isPending.value = false;
  };

  return {
    state,
    isPending,
    canUndo,
    canRedo,
    undoTooltip,
    redoTooltip,
    configureTransport,
    requestUndo,
    requestRedo,
    handleStateUpdate,
    resolveUndoRequest,
    resolveRedoRequest,
  };
});
