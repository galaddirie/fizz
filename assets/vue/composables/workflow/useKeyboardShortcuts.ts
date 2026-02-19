interface UseKeyboardShortcutsOptions {
  canEdit: () => boolean;
  canPaste: () => boolean;
  canGroupSelection: () => boolean;
  canUngroupSelection: () => boolean;
  resolveActiveNodeIds: () => string[];
  handleCopySteps: (stepIds: string[]) => void;
  handlePasteSteps: () => void;
  handleCutSteps: (stepIds: string[]) => void;
  createGroupFromSelection: () => void;
  ungroupSelectedSteps: () => void;
  undo: (callback: () => void) => void;
  redo: (callback: () => void) => void;
  sendUndo: () => void;
  sendRedo: () => void;
}

const isEditableTarget = (target: EventTarget | null) => {
  if (!(target instanceof HTMLElement)) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName.toLowerCase();
  return tag === 'input' || tag === 'textarea' || tag === 'select';
};

export function useKeyboardShortcuts(options: UseKeyboardShortcutsOptions) {
  const handleGlobalKeydown = (event: KeyboardEvent) => {
    if (!options.canEdit()) return;
    if (event.repeat || isEditableTarget(event.target)) return;
    if (!event.metaKey && !event.ctrlKey) return;

    const key = event.key.toLowerCase();
    if (key === 'z') {
      event.preventDefault();
      if (event.shiftKey) {
        options.redo(options.sendRedo);
      } else {
        options.undo(options.sendUndo);
      }
      return;
    }

    if (key === 'c') {
      const stepIds = options.resolveActiveNodeIds();
      if (!stepIds.length) return;
      event.preventDefault();
      options.handleCopySteps(stepIds);
      return;
    }

    if (key === 'v') {
      if (!options.canPaste()) return;
      event.preventDefault();
      options.handlePasteSteps();
      return;
    }

    if (key === 'x') {
      const stepIds = options.resolveActiveNodeIds();
      if (!stepIds.length) return;
      event.preventDefault();
      options.handleCutSteps(stepIds);
      return;
    }

    if (key === 'g') {
      if (event.shiftKey) {
        if (!options.canUngroupSelection()) return;
        event.preventDefault();
        options.ungroupSelectedSteps();
        return;
      }

      if (!options.canGroupSelection()) return;
      event.preventDefault();
      options.createGroupFromSelection();
    }
  };

  const registerShortcuts = () => {
    window.addEventListener('keydown', handleGlobalKeydown);
  };

  const unregisterShortcuts = () => {
    window.removeEventListener('keydown', handleGlobalKeydown);
  };

  return {
    registerShortcuts,
    unregisterShortcuts,
  };
}
