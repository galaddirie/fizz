import { ref } from "vue";
import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";

import WorkflowEditorRoot from "./WorkflowEditorRoot.vue";

vi.mock("./controllers/useWorkflowEditorRoot", () => ({
  useWorkflowEditorRoot: (
    _props: unknown,
    emitAction: (action: unknown) => void
  ) => ({
    editor: {
      nodeLibraryItems: [],
      presences: [],
      commands: {
        document: {
          save: () => emitAction({ type: "document.save" }),
          undo: vi.fn(),
          redo: vi.fn(),
        },
        execution: {
          runTest: vi.fn(),
          cancel: vi.fn(),
        },
        selection: {
          selectStep: vi.fn(),
        },
        inspector: {
          saveStepConfig: vi.fn(),
          deleteStep: vi.fn(),
          previewExpression: vi.fn(),
          pinOutput: vi.fn(),
          unpinOutput: vi.fn(),
        },
        step: {
          run: vi.fn(),
        },
      },
      undoStore: {
        canUndo: false,
        canRedo: false,
        undoTooltip: "Undo",
        redoTooltip: "Redo",
        isPending: false,
      },
      store: {
        snapEnabled: false,
        selectedNodeId: null,
        isTracePanelExpanded: false,
        toggleTracePanel: vi.fn(),
        closeConfigModal: vi.fn(),
        contextMenu: { show: false, x: 0, y: 0 },
        isConfigModalOpen: false,
      },
      execution: null,
      stepExecutions: [],
      stepNameById: {},
      selectedNode: null,
      selectedStepType: null,
      expressionPreviews: {},
      incomingStepIdsByStepId: {},
      incomingConnectionsByTargetInputByStepId: {},
      upstreamStepIdsByStepId: {},
      contextMenuItems: [],
      isAddStepPickerOpen: false,
      addStepPickerX: 0,
      addStepPickerY: 0,
      addStepPickerItems: [],
      handleContextMenuSelect: vi.fn(),
      closeContextMenu: vi.fn(),
      handleAddStepPickerSelect: vi.fn(),
      closeAddStepPicker: vi.fn(),
      isMounted: true,
      viewport: { x: 0, y: 0, zoom: 1 },
      otherUserPresences: [],
      currentUserId: "user-1",
      isExecutionFailed: false,
      isExecutionRunning: false,
    },
    chrome: {
      workflow: ref({
        id: "wf-1",
        name: "Workflow",
        status: "draft",
        public: false,
        user_id: "user-1",
        inserted_at: "2024-01-01T00:00:00Z",
        updated_at: "2024-01-01T00:00:00Z",
        workspace: { name: "Workspace" },
        workspace_id: "ws-1",
      }),
      workspaceLink: ref("/workspaces/ws-1"),
      workflowExecutionsLink: ref("/workflows/wf-1"),
      nodeLibraryWidth: ref(288),
      isNodeLibraryCollapsed: ref(false),
      handleNodeLibraryResizeStart: vi.fn(),
      toggleNodeLibraryCollapsed: vi.fn(),
      isPublishModalOpen: ref(true),
      isPublishing: ref(false),
      publishError: ref<string | null>(null),
      openPublishModal: vi.fn(),
      closePublishModal: vi.fn(),
      handlePublish: (payload: { version_tag: string; changelog: string }) =>
        emitAction({ type: "document.publish", payload }),
      lastSaved: ref("just now"),
      lastSavedExact: ref("Saved just now"),
      isDebugMode: ref(false),
      debugExecutionShortId: ref("exec-1"),
      debugExecutionTimestamp: ref<string | null>(null),
      debugStatusBadge: ref({ dotClass: "bg-primary", label: "Running" }),
      debugExecutionLink: ref<string | null>(null),
      debugExitLink: ref<string | null>(null),
      emitRevisionOpenAction: () => emitAction({ type: "revision.open" }),
    },
    sceneModel: {
      nodes: [],
      edges: [],
      nodeTypes: {},
      edgeTypes: {},
      snapEnabled: false,
      gridSize: 24,
      effectiveSnapToGrid: false,
      canEdit: true,
      miniMapNodeColor: () => "#000",
    },
    sceneController: {
      setCanvasRef: vi.fn(),
      setVueFlowRef: vi.fn(),
    },
  }),
}));

describe("WorkflowEditorRoot", () => {
  it("emits grouped actions from root chrome interactions", async () => {
    const wrapper = mount(WorkflowEditorRoot, {
      props: {
        document: {
          workflow: {
            id: "wf-1",
            name: "Workflow",
            status: "draft",
            public: false,
            user_id: "user-1",
            inserted_at: "2024-01-01T00:00:00Z",
            updated_at: "2024-01-01T00:00:00Z",
          },
          expressionPreviews: {},
        },
        catalog: {
          stepTypes: [],
          nodeLibraryItems: [],
          credentialOptions: [],
        },
        execution: {
          execution: null,
          stepExecutions: [],
          debugExecutionId: null,
        },
        collaboration: {
          presences: [],
          currentUserId: "user-1",
          collabSeq: 0,
        },
      },
      global: {
        stubs: {
          NodeLibrary: true,
          WorkflowSceneCanvas: true,
          ExecutionTracePanel: true,
          StepConfigModal: true,
          ContextMenu: true,
          AddStepPicker: true,
          WorkflowEditorInfoPanel: {
            emits: ["save"],
            template:
              '<button id="info-save" @click="$emit(\'save\')">Save</button>',
          },
          EditorToolbar: {
            emits: ["open-revisions", "publish"],
            template: `
              <div>
                <button id="open-revisions" @click="$emit('open-revisions')">Revisions</button>
                <button id="open-publish" @click="$emit('publish')">Publish</button>
              </div>
            `,
          },
          PublishModal: {
            emits: ["publish"],
            template:
              "<button id=\"publish-submit\" @click=\"$emit('publish', { version_tag: 'v1', changelog: 'notes' })\">Submit publish</button>",
          },
        },
      },
    });

    await wrapper.find("#open-revisions").trigger("click");
    await wrapper.find("#info-save").trigger("click");
    await wrapper.find("#publish-submit").trigger("click");

    expect(wrapper.emitted("action")).toEqual([
      [{ type: "revision.open" }],
      [{ type: "document.save" }],
      [
        {
          type: "document.publish",
          payload: { version_tag: "v1", changelog: "notes" },
        },
      ],
    ]);
  });
});
