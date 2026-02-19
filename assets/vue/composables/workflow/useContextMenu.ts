import { computed } from 'vue';

import type { MenuItem } from '@/components/ui/ContextMenu.vue';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';
import type { StepNodeData } from '@/types/workflow';
import type { Node } from '@vue-flow/core';
import {
  TrashIcon,
  DocumentDuplicateIcon,
  Cog6ToothIcon,
  EyeSlashIcon,
  BookmarkIcon,
  PlayIcon,
  PlusIcon,
  ClipboardDocumentIcon,
  ScissorsIcon,
  ArrowPathIcon,
  RectangleGroupIcon,
  FolderMinusIcon,
  MagnifyingGlassIcon,
} from '@heroicons/vue/24/outline';

interface UseContextMenuOptions {
  store: ReturnType<typeof useClientStore>;
  canEdit: () => boolean;
  tidyLabel: () => string;
  canPaste: () => boolean;
  canGroupSelection: () => boolean;
  canUngroupSelection: () => boolean;
  findStepNodeById: (id: string) => Node<StepNodeData> | null;
  resolveActiveNodeIds: (fallbackNodeId?: string | null) => string[];
  createGroupFromSelection: () => void;
  ungroupSelectedSteps: () => void;
  removeGroup: (id: string) => void;
  handleLayout: (options?: { groupId?: string }) => void;
  handleRunNode: (stepId: string) => void;
  handleDuplicateSteps: (stepIds: string[]) => void;
  handleCopySteps: (stepIds: string[]) => void;
  handleCutSteps: (stepIds: string[]) => void;
  handlePasteSteps: () => void;
  requestNodeRemoval: (id: string) => void;
  handleTogglePin: (stepId: string, isPinned: boolean) => void;
  emit: WorkflowEditorEmits;
}

export function useContextMenu(options: UseContextMenuOptions) {
  const contextMenuItems = computed<MenuItem[]>(() => {
    const targetType = options.store.contextMenu.targetType;
    const targetNodeId = options.store.contextMenu.targetNodeId;

    if (!options.canEdit()) {
      if (targetType === 'node' && targetNodeId) {
        const node = options.findStepNodeById(targetNodeId);
        if (node) {
          return [
            { id: 'inspect', label: 'Inspect Step', icon: MagnifyingGlassIcon },
            { id: 'divider-1', label: '', divider: true },
            { id: 'fit-view', label: 'Fit to View', shortcut: '\u23181' },
          ];
        }
      }

      return [{ id: 'fit-view', label: 'Fit to View', shortcut: '\u23181' }];
    }

    if (targetType === 'node' && targetNodeId) {
      const node = options.findStepNodeById(targetNodeId);
      if (!node) {
        return [
          { id: 'tidy-group', label: 'Tidy up node group', icon: ArrowPathIcon },
          { id: 'divider-group', label: '', divider: true },
          { id: 'delete-group', label: 'Remove Group', icon: TrashIcon, danger: true },
        ];
      }

      const isDisabled = node.data?.disabled;
      const isPinned = node.data?.pinned;
      const groupItems: MenuItem[] = [];
      if (options.canGroupSelection()) {
        groupItems.push({
          id: 'group-selection',
          label: 'Group Selection',
          icon: RectangleGroupIcon,
          shortcut: '\u2318G',
        });
      }
      if (options.canUngroupSelection()) {
        groupItems.push({
          id: 'ungroup-selection',
          label: 'Remove from Group',
          icon: FolderMinusIcon,
        });
      }

      return [
        { id: 'edit', label: 'Edit Step', icon: Cog6ToothIcon, shortcut: 'Enter' },
        { id: 'run-from', label: 'Run from Here', icon: PlayIcon },
        ...(groupItems.length ? [{ id: 'divider-groups', label: '', divider: true }] : []),
        ...groupItems,
        { id: 'divider-1', label: '', divider: true },
        { id: 'tidy-layout', label: options.tidyLabel(), icon: ArrowPathIcon },
        { id: 'duplicate', label: 'Duplicate', icon: DocumentDuplicateIcon, shortcut: '\u2318D' },
        { id: 'copy', label: 'Copy', icon: ClipboardDocumentIcon, shortcut: '\u2318C' },
        { id: 'cut', label: 'Cut', icon: ScissorsIcon, shortcut: '\u2318X' },
        { id: 'divider-2', label: '', divider: true },
        {
          id: 'toggle-disable',
          label: isDisabled ? 'Enable Step' : 'Disable Step',
          icon: EyeSlashIcon,
        },
        { id: 'toggle-pin', label: isPinned ? 'Unpin Output' : 'Pin Output', icon: BookmarkIcon },
        { id: 'divider-3', label: '', divider: true },
        { id: 'delete', label: 'Delete', icon: TrashIcon, shortcut: '\u232B', danger: true },
      ];
    }

    return [
      { id: 'add-step', label: 'Add Step', icon: PlusIcon },
      {
        id: 'paste',
        label: 'Paste',
        icon: ClipboardDocumentIcon,
        shortcut: '\u2318V',
        disabled: !options.canPaste(),
      },
      { id: 'divider-1', label: '', divider: true },
      { id: 'select-all', label: 'Select All', shortcut: '\u2318A' },
      { id: 'tidy-layout', label: options.tidyLabel(), icon: ArrowPathIcon },
      { id: 'fit-view', label: 'Fit to View', shortcut: '\u23181' },
    ];
  });

  const handleContextMenuSelect = (itemId: string) => {
    const nodeId = options.store.contextMenu.targetNodeId;

    if (!options.canEdit()) {
      if (itemId === 'inspect' && nodeId) {
        options.store.openConfigModal(nodeId);
      }
      options.store.hideContextMenu();
      return;
    }

    switch (itemId) {
      case 'group-selection':
        options.createGroupFromSelection();
        break;
      case 'ungroup-selection':
        options.ungroupSelectedSteps();
        break;
      case 'delete-group':
        if (nodeId) options.removeGroup(nodeId);
        break;
      case 'tidy-group':
        if (nodeId) options.handleLayout({ groupId: nodeId });
        break;
      case 'edit':
        if (nodeId) options.store.openConfigModal(nodeId);
        break;
      case 'delete':
        if (nodeId) options.requestNodeRemoval(nodeId);
        break;
      case 'duplicate':
        options.handleDuplicateSteps(options.resolveActiveNodeIds(nodeId));
        break;
      case 'copy':
        options.handleCopySteps(options.resolveActiveNodeIds(nodeId));
        break;
      case 'cut':
        options.handleCutSteps(options.resolveActiveNodeIds(nodeId));
        break;
      case 'paste':
        options.handlePasteSteps();
        break;
      case 'toggle-disable':
        if (nodeId) {
          const stepNode = options.findStepNodeById(nodeId);
          if (!stepNode) break;
          if (stepNode.data?.disabled) {
            options.emit('enable_step', { step_id: nodeId });
          } else {
            options.emit('disable_step', { step_id: nodeId, mode: 'skip' });
          }
        }
        break;
      case 'toggle-pin':
        if (nodeId) {
          const stepNode = options.findStepNodeById(nodeId);
          if (!stepNode) break;
          options.handleTogglePin(nodeId, !!stepNode.data?.pinned);
        }
        break;
      case 'add-step':
        options.store.isLibraryOpen = true;
        break;
      case 'tidy-layout':
        options.handleLayout();
        break;
      case 'run-from':
        if (nodeId) options.handleRunNode(nodeId);
        break;
      case 'select-all':
      case 'fit-view':
        break;
    }

    options.store.hideContextMenu();
  };

  return {
    contextMenuItems,
    handleContextMenuSelect,
  };
}
