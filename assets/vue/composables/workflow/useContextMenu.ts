import { computed } from "vue";

import {
  ArrowPathIcon,
  BookmarkIcon,
  ClipboardDocumentIcon,
  Cog6ToothIcon,
  DocumentDuplicateIcon,
  EyeSlashIcon,
  FolderMinusIcon,
  MagnifyingGlassIcon,
  PlayIcon,
  PlusIcon,
  RectangleGroupIcon,
  ScissorsIcon,
  TrashIcon,
} from "@heroicons/vue/24/outline";
import type { Node } from "@vue-flow/core";

import type { MenuItem } from "@/components/ui/ContextMenu.vue";
import type { StepNodeData } from "@/shared/ui/workflow-scene/types";
import type { useClientStore } from "@/stores/clientStore";

type ContextMenuCommand = MenuItem & {
  execute?: () => void;
};

interface UseContextMenuOptions {
  store: ReturnType<typeof useClientStore>;
  canEdit: () => boolean;
  state: {
    tidyLabel: () => string;
    canPaste: () => boolean;
    canGroupSelection: () => boolean;
    canUngroupSelection: () => boolean;
  };
  lookup: {
    findStepNodeById: (id: string) => Node<StepNodeData> | null;
    resolveActiveNodeIds: (fallbackNodeId?: string | null) => string[];
  };
  commands: {
    canvas: {
      openAddStepPicker: (screenPoint: { x: number; y: number }) => void;
      fitView: () => void;
      selectAll: () => void;
    };
    group: {
      createFromSelection: () => void;
      ungroupSelection: () => void;
      remove: (groupId: string) => void;
      tidy: (options?: { groupId?: string }) => void;
    };
    clipboard: {
      duplicate: (stepIds: string[]) => void;
      copy: (stepIds: string[]) => void;
      cut: (stepIds: string[]) => void;
      paste: () => void;
    };
    step: {
      inspect: (stepId: string) => void;
      remove: (stepId: string) => void;
      run: (stepId: string) => void;
      toggleDisabled: (stepId: string, isDisabled: boolean) => void;
      togglePin: (stepId: string, isPinned: boolean) => void;
    };
  };
}

const divider = (id: string): ContextMenuCommand => ({
  id,
  label: "",
  divider: true,
});

const command = (item: MenuItem, execute?: () => void): ContextMenuCommand => ({
  ...item,
  execute,
});

const createReadonlyCommands = (
  options: UseContextMenuOptions,
  targetNodeId: string | null
) => {
  if (targetNodeId) {
    const node = options.lookup.findStepNodeById(targetNodeId);
    if (node) {
      return [
        command(
          {
            id: "inspect",
            label: "Inspect Step",
            icon: MagnifyingGlassIcon,
          },
          () => options.commands.step.inspect(targetNodeId)
        ),
        divider("divider-1"),
        command(
          {
            id: "fit-view",
            label: "Fit to View",
            shortcut: "\u23181",
          },
          options.commands.canvas.fitView
        ),
      ];
    }
  }

  return [
    command(
      {
        id: "fit-view",
        label: "Fit to View",
        shortcut: "\u23181",
      },
      options.commands.canvas.fitView
    ),
  ];
};

const createGroupCommands = (
  options: UseContextMenuOptions,
  groupId: string
): ContextMenuCommand[] => [
  command(
    {
      id: "tidy-group",
      label: "Tidy up node group",
      icon: ArrowPathIcon,
    },
    () => options.commands.group.tidy({ groupId })
  ),
  divider("divider-group"),
  command(
    {
      id: "delete-group",
      label: "Remove Group",
      icon: TrashIcon,
      danger: true,
    },
    () => options.commands.group.remove(groupId)
  ),
];

const createSelectionGroupCommands = (options: UseContextMenuOptions) => {
  const selectionCommands: ContextMenuCommand[] = [];

  if (options.state.canGroupSelection()) {
    selectionCommands.push(
      command(
        {
          id: "group-selection",
          label: "Group Selection",
          icon: RectangleGroupIcon,
          shortcut: "\u2318G",
        },
        options.commands.group.createFromSelection
      )
    );
  }

  if (options.state.canUngroupSelection()) {
    selectionCommands.push(
      command(
        {
          id: "ungroup-selection",
          label: "Remove from Group",
          icon: FolderMinusIcon,
        },
        options.commands.group.ungroupSelection
      )
    );
  }

  return selectionCommands;
};

const createStepCommands = (
  options: UseContextMenuOptions,
  stepId: string,
  node: Node<StepNodeData>
): ContextMenuCommand[] => {
  const selectionCommands = createSelectionGroupCommands(options);
  const isDisabled = !!node.data?.disabled;
  const isPinned = !!node.data?.pinned;

  return [
    command(
      {
        id: "edit",
        label: "Edit Step",
        icon: Cog6ToothIcon,
        shortcut: "Enter",
      },
      () => options.commands.step.inspect(stepId)
    ),
    command(
      {
        id: "run-from",
        label: "Run from Here",
        icon: PlayIcon,
      },
      () => options.commands.step.run(stepId)
    ),
    ...(selectionCommands.length
      ? [divider("divider-groups"), ...selectionCommands]
      : []),
    divider("divider-1"),
    command(
      {
        id: "tidy-layout",
        label: options.state.tidyLabel(),
        icon: ArrowPathIcon,
      },
      () => options.commands.group.tidy()
    ),
    command(
      {
        id: "duplicate",
        label: "Duplicate",
        icon: DocumentDuplicateIcon,
        shortcut: "\u2318D",
      },
      () =>
        options.commands.clipboard.duplicate(
          options.lookup.resolveActiveNodeIds(stepId)
        )
    ),
    command(
      {
        id: "copy",
        label: "Copy",
        icon: ClipboardDocumentIcon,
        shortcut: "\u2318C",
      },
      () =>
        options.commands.clipboard.copy(
          options.lookup.resolveActiveNodeIds(stepId)
        )
    ),
    command(
      {
        id: "cut",
        label: "Cut",
        icon: ScissorsIcon,
        shortcut: "\u2318X",
      },
      () =>
        options.commands.clipboard.cut(
          options.lookup.resolveActiveNodeIds(stepId)
        )
    ),
    divider("divider-2"),
    command(
      {
        id: "toggle-disable",
        label: isDisabled ? "Enable Step" : "Disable Step",
        icon: EyeSlashIcon,
      },
      () => options.commands.step.toggleDisabled(stepId, isDisabled)
    ),
    command(
      {
        id: "toggle-pin",
        label: isPinned ? "Unpin Output" : "Pin Output",
        icon: BookmarkIcon,
      },
      () => options.commands.step.togglePin(stepId, isPinned)
    ),
    divider("divider-3"),
    command(
      {
        id: "delete",
        label: "Delete",
        icon: TrashIcon,
        shortcut: "\u232B",
        danger: true,
      },
      () => options.commands.step.remove(stepId)
    ),
  ];
};

const createPaneCommands = (
  options: UseContextMenuOptions
): ContextMenuCommand[] => [
  command(
    {
      id: "add-step",
      label: "Add Step",
      icon: PlusIcon,
    },
    () =>
      options.commands.canvas.openAddStepPicker({
        x: options.store.contextMenu.x,
        y: options.store.contextMenu.y,
      })
  ),
  command(
    {
      id: "paste",
      label: "Paste",
      icon: ClipboardDocumentIcon,
      shortcut: "\u2318V",
      disabled: !options.state.canPaste(),
    },
    options.commands.clipboard.paste
  ),
  divider("divider-1"),
  command(
    {
      id: "select-all",
      label: "Select All",
      shortcut: "\u2318A",
    },
    options.commands.canvas.selectAll
  ),
  command(
    {
      id: "tidy-layout",
      label: options.state.tidyLabel(),
      icon: ArrowPathIcon,
    },
    () => options.commands.group.tidy()
  ),
  command(
    {
      id: "fit-view",
      label: "Fit to View",
      shortcut: "\u23181",
    },
    options.commands.canvas.fitView
  ),
];

const createCommands = (options: UseContextMenuOptions) => {
  const { targetNodeId, targetType } = options.store.contextMenu;

  if (!options.canEdit()) {
    return createReadonlyCommands(
      options,
      targetType === "node" ? targetNodeId : null
    );
  }

  if (targetType === "node" && targetNodeId) {
    const node = options.lookup.findStepNodeById(targetNodeId);
    return node
      ? createStepCommands(options, targetNodeId, node)
      : createGroupCommands(options, targetNodeId);
  }

  return createPaneCommands(options);
};

export function useContextMenu(options: UseContextMenuOptions) {
  const menuCommands = computed(() => createCommands(options));
  const contextMenuItems = computed<MenuItem[]>(() =>
    menuCommands.value.map(({ execute, ...item }) => item)
  );

  const handleContextMenuSelect = (itemId: string) => {
    const selectedCommand = menuCommands.value.find(
      (item) => item.id === itemId
    );

    selectedCommand?.execute?.();
    options.store.hideContextMenu();
  };

  return {
    contextMenuItems,
    handleContextMenuSelect,
  };
}
