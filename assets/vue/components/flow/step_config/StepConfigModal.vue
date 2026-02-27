<script setup lang="ts">
import { onBeforeUnmount, onMounted, provide } from 'vue';
import type { Node } from '@vue-flow/core';
import type {
  EditorState,
  Execution,
  StepExecution,
  StepNodeData,
  StepType,
} from '@/types/workflow';
import { CubeIcon, XMarkIcon, PencilIcon } from '@heroicons/vue/24/outline';
import { useStepConfig, StepConfigKey } from './useStepConfig';
import StepConfigContextPane from './StepConfigContextPane.vue';
import StepConfigConfigPane from './StepConfigConfigPane.vue';
import StepConfigOutputPane from './StepConfigOutputPane.vue';
import ConfirmDiscardModal from './ConfirmDiscardModal.vue';

interface Props {
  node: Node<StepNodeData> | null;
  isOpen: boolean;
  canEdit?: boolean;
  stepType?: StepType | null;
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  expressionPreviews?: Record<string, unknown>;
  editorState?: EditorState;
  stepNameById?: Record<string, string>;
  incomingStepIds?: Record<string, string[]>;
  incomingConnectionsByTargetInput?: Record<string, Record<string, string[]>>;
  upstreamStepIds?: Record<string, string[]>;
}

const props = defineProps<Props>();
const emit = defineEmits([
  'close',
  'save',
  'preview_expression',
  'toggle_webhook_test',
  'pin_output',
  'unpin_output',
  'run_node',
]);

const state = useStepConfig(props, emit);
provide(StepConfigKey, state);

const handleEscape = (event: KeyboardEvent) => {
  if (!props.isOpen) return;
  if (event.key !== 'Escape') return;

  event.preventDefault();
  state.closeModal();
};

onMounted(() => {
  window.addEventListener('keydown', handleEscape);
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', handleEscape);
});
</script>

<template>
  <div
    v-if="isOpen"
    class="fixed inset-0 z-[1100] flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm sm:p-6"
  >
    <div
      class="bg-base-100 border-base-300 animate-in fade-in zoom-in flex h-[90vh] w-full max-w-[1600px] flex-col overflow-hidden rounded-3xl border shadow-2xl duration-300"
      @mousedown.stop
    >
      <!-- Header -->
      <div
        class="border-base-200 bg-base-200/40 flex items-center justify-between border-b px-6 py-4"
      >
        <div class="flex items-center gap-4">
          <div
            class="bg-primary/10 text-primary flex h-12 w-12 items-center justify-center rounded-2xl shadow-inner"
          >
            <CubeIcon class="h-6 w-6" />
          </div>
          <div>
            <div class="flex items-center gap-2">
              <div v-if="state.isEditingName.value && state.canEdit.value" class="flex items-center gap-2">
                <input
                  v-model="state.editName.value"
                  type="text"
                  class="input input-sm input-primary bg-base-100 border-base-300 text-lg font-bold"
                  @keyup.enter="state.isEditingName.value = false"
                  @blur="state.isEditingName.value = false"
                  auto-focus
                />
              </div>
              <h2
                v-else
                class="text-base-content group/name flex items-center gap-2 text-lg leading-none font-bold"
              >
                {{ state.editName.value }}
                <button
                  v-if="state.canEdit.value"
                  class="btn btn-ghost btn-xs btn-circle opacity-0 transition-opacity group-hover/name:opacity-100"
                  @click="state.isEditingName.value = true"
                >
                  <PencilIcon class="text-base-content/40 size-3.5" />
                </button>
              </h2>
              <span class="badge badge-primary badge-sm font-mono opacity-80">{{
                node?.id.slice(0, 8)
              }}</span>
            </div>
            <p class="text-base-content/50 mt-1 flex items-center gap-1.5 text-xs font-medium">
              <span class="bg-success h-1.5 w-1.5 rounded-full"></span>
              {{ node?.data?.type_id }} Step
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <button
            class="btn btn-ghost btn-sm btn-circle hover:bg-error/10 hover:text-error ml-4"
            @click="state.closeModal()"
          >
            <XMarkIcon class="h-5 w-5" />
          </button>
        </div>
      </div>

      <!-- Main content 3-pane layout -->
      <div class="bg-base-200/20 flex flex-1 overflow-hidden">
        <StepConfigContextPane class="shrink-0" />

        <div class="flex-1 custom-scrollbar overflow-y-auto border-r border-base-200 p-8">
          <StepConfigConfigPane />
        </div>

        <div class="w-[400px] xl:w-[500px] shrink-0 bg-base-100/30 overflow-hidden">
          <StepConfigOutputPane />
        </div>
      </div>

      <!-- Footer -->
      <div class="border-base-200 bg-base-100 flex items-center justify-end border-t px-8 py-5">
        <div class="flex items-center gap-4">
          <template v-if="state.canEdit.value">
            <button class="btn btn-ghost btn-sm text-base-content/60 font-bold" @click="state.closeModal()">
              Discard Changes
            </button>
            <button
              class="btn btn-primary shadow-primary/20 rounded-xl px-8 font-bold shadow-lg"
              @click="state.saveConfig()"
            >
              Save Configuration
            </button>
          </template>
          <template v-else>
            <button class="btn btn-ghost btn-sm text-base-content/60 font-bold" @click="state.closeModal()">
              Close
            </button>
          </template>
        </div>
      </div>

      <ConfirmDiscardModal
        :show="state.showCloseConfirmation.value"
        @confirm="state.confirmClose()"
        @cancel="state.cancelClose()"
      />
    </div>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 6px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
  border-radius: 10px;
}
</style>
