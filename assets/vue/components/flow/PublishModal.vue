<script setup lang="ts">
import { computed } from 'vue';
import {
  ArrowsRightLeftIcon,
  CheckCircleIcon,
  ExclamationTriangleIcon,
  RocketLaunchIcon,
  SparklesIcon,
  XMarkIcon,
} from '@heroicons/vue/24/outline';
import type { TriggerImpact, WorkflowValidationError } from '@/types/workflow';

interface Props {
  isOpen: boolean;
  workflowName?: string;
  versionNumber?: number | null;
  isPublishing?: boolean;
  isValidating?: boolean;
  publishError?: string | null;
  validationErrors?: WorkflowValidationError[];
  triggerImpact?: TriggerImpact | null;
  executionHashChanged?: boolean | null;
}

const props = withDefaults(defineProps<Props>(), {
  workflowName: 'Workflow',
  versionNumber: null,
  isPublishing: false,
  isValidating: false,
  publishError: null,
  validationErrors: () => [],
  triggerImpact: null,
  executionHashChanged: null,
});

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'publish'): void;
}>();

const blockingErrors = computed(() =>
  props.validationErrors.filter(error => error.severity !== 'warning')
);
const warningErrors = computed(() =>
  props.validationErrors.filter(error => error.severity === 'warning')
);
const hasBlockingErrors = computed(() => blockingErrors.value.length > 0);
const hasValidationErrors = computed(() => props.validationErrors.length > 0);
const canPublish = computed(() => {
  return (
    typeof props.versionNumber === 'number' &&
    !props.isPublishing &&
    !props.isValidating &&
    !hasBlockingErrors.value
  );
});

const impactCounts = computed(() => ({
  added: props.triggerImpact?.added.length ?? 0,
  updated: props.triggerImpact?.updated.length ?? 0,
  removed: props.triggerImpact?.removed.length ?? 0,
  unchanged: props.triggerImpact?.unchanged_count ?? 0,
}));

const impactDetails = computed(() => [
  ...(props.triggerImpact?.added ?? []).map(entry => ({
    id: `added-${entry.step_id}`,
    label: `${entry.kind} trigger for step ${entry.step_id} will be activated.`,
    tone: 'success',
  })),
  ...(props.triggerImpact?.updated ?? []).map(entry => ({
    id: `updated-${entry.step_id}`,
    label: `${entry.kind} trigger for step ${entry.step_id} will be updated.`,
    tone: 'warning',
  })),
  ...(props.triggerImpact?.removed ?? []).map(entry => ({
    id: `removed-${entry.step_id}`,
    label: `${entry.kind} trigger for step ${entry.step_id} will be removed.`,
    tone: 'error',
  })),
]);

const executionHashState = computed(() => {
  if (props.executionHashChanged === true) {
    return {
      title: 'Execution hash will change',
      description: 'This publish changes runtime behavior and will produce a new compiled hash.',
      className: 'border-primary/20 bg-primary/5 text-primary',
    };
  }

  if (props.executionHashChanged === false) {
    return {
      title: 'Execution hash unchanged',
      description: 'This publish only changes editor metadata. Runtime behavior stays the same.',
      className: 'border-success/20 bg-success/5 text-success',
    };
  }

  return {
    title: 'Execution hash pending',
    description: 'Hash impact is unavailable until the draft compiles successfully.',
    className: 'border-base-300/60 bg-base-200/40 text-base-content/70',
  };
});

const publishButtonLabel = computed(() => {
  if (props.isPublishing) return 'Publishing...';
  if (props.isValidating) return 'Validating...';
  if (typeof props.versionNumber === 'number') return `Publish Version ${props.versionNumber}`;
  return 'Publish Workflow';
});

function handlePublish() {
  if (!canPublish.value) return;
  emit('publish');
}

function handleClose() {
  if (!props.isPublishing) {
    emit('close');
  }
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="isOpen"
        class="fixed inset-0 z-50 flex items-center justify-center p-4"
        @click.self="handleClose"
      >
        <!-- Backdrop -->
        <div class="bg-base-300/80 fixed inset-0 backdrop-blur-sm" @click="handleClose" />

        <!-- Modal -->
        <div
          class="bg-base-100 border-base-200 relative z-10 w-full max-w-2xl rounded-3xl border shadow-2xl"
          @click.stop
        >
          <!-- Header -->
          <div class="border-base-200 flex items-center justify-between border-b px-6 py-4">
            <div class="flex items-center gap-3">
              <div class="bg-primary/10 text-primary flex h-10 w-10 items-center justify-center rounded-xl">
                <RocketLaunchIcon class="h-5 w-5" />
              </div>
              <div>
                <h2 class="text-base-content text-lg font-semibold">Publish Workflow</h2>
                <p class="text-base-content/50 text-xs">{{ workflowName }}</p>
              </div>
            </div>
            <button
              class="btn btn-ghost btn-sm btn-circle"
              :disabled="isPublishing"
              @click="handleClose"
            >
              <XMarkIcon class="h-5 w-5" />
            </button>
          </div>

          <!-- Content -->
          <div class="space-y-4 p-6">
            <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
              <div class="rounded-2xl border border-primary/20 bg-primary/5 p-4">
                <div class="flex items-start gap-3">
                  <div class="bg-primary/10 text-primary flex h-10 w-10 items-center justify-center rounded-xl">
                    <SparklesIcon class="h-5 w-5" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-[11px] font-semibold uppercase tracking-[0.16em] text-primary/70">
                      Publishing
                    </p>
                    <h3 class="mt-1 text-lg font-semibold text-base-content">
                      <template v-if="typeof versionNumber === 'number'">
                        Version {{ versionNumber }}
                      </template>
                      <template v-else>
                        Next version
                      </template>
                    </h3>
                    <p class="mt-1 text-sm text-base-content/60">
                      Version numbers are assigned automatically from the draft snapshot.
                    </p>
                  </div>
                </div>
              </div>

              <div class="rounded-2xl border p-4" :class="executionHashState.className">
                <div class="flex items-start gap-3">
                  <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-base-100/70">
                    <ArrowsRightLeftIcon class="h-5 w-5" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-[11px] font-semibold uppercase tracking-[0.16em]">
                      Execution hash
                    </p>
                    <h3 class="mt-1 text-sm font-semibold">{{ executionHashState.title }}</h3>
                    <p class="mt-1 text-sm/6 opacity-80">{{ executionHashState.description }}</p>
                  </div>
                </div>
              </div>
            </div>

            <div class="rounded-2xl border border-base-300/60 bg-base-200/40 p-4">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h3 class="text-sm font-semibold text-base-content">Publish checklist</h3>
                  <p class="mt-1 text-xs text-base-content/60">
                    Review publish-time validation before creating the immutable version.
                  </p>
                </div>
                <span
                  v-if="isValidating"
                  class="loading loading-spinner loading-sm text-primary"
                />
                <div
                  v-else
                  class="rounded-full px-3 py-1 text-xs font-semibold"
                  :class="
                    hasBlockingErrors
                      ? 'bg-error/10 text-error'
                      : 'bg-success/10 text-success'
                  "
                >
                  {{ hasBlockingErrors ? `${blockingErrors.length} issue(s)` : 'Ready to publish' }}
                </div>
              </div>

              <div v-if="isValidating" class="mt-4 text-sm text-base-content/60">
                Running publish-time validation…
              </div>

              <div v-else-if="hasValidationErrors" class="mt-4 space-y-2">
                <div class="flex flex-wrap gap-2 text-[11px] font-medium">
                  <span
                    class="rounded-full px-2.5 py-1"
                    :class="hasBlockingErrors ? 'bg-error/10 text-error' : 'bg-success/10 text-success'"
                  >
                    {{ blockingErrors.length }} blocking
                  </span>
                  <span class="rounded-full bg-warning/10 px-2.5 py-1 text-warning">
                    {{ warningErrors.length }} warning
                  </span>
                </div>
                <div
                  v-for="(error, index) in validationErrors"
                  :key="`${error.code}-${error.step_id ?? 'global'}-${error.field ?? 'field'}-${index}`"
                  class="rounded-xl border px-3 py-2"
                  :class="
                    error.severity === 'warning'
                      ? 'border-warning/20 bg-warning/5'
                      : 'border-error/20 bg-error/5'
                  "
                >
                  <div class="flex items-start gap-2">
                    <ExclamationTriangleIcon
                      class="mt-0.5 h-4 w-4 shrink-0"
                      :class="error.severity === 'warning' ? 'text-warning' : 'text-error'"
                    />
                    <div class="min-w-0">
                      <p class="text-sm font-medium text-base-content">{{ error.message }}</p>
                      <p class="mt-1 text-[11px] uppercase tracking-[0.12em] text-base-content/45">
                        <span v-if="error.step_id">Step {{ error.step_id }}</span>
                        <span v-if="error.step_id && error.field"> · </span>
                        <span v-if="error.field">{{ error.field }}</span>
                        <span v-if="error.code"> · {{ error.code.replace(/_/g, ' ') }}</span>
                      </p>
                    </div>
                  </div>
                </div>
              </div>

              <div
                v-else
                class="mt-4 flex items-center gap-2 rounded-xl border border-success/20 bg-success/5 px-3 py-2 text-sm text-success"
              >
                <CheckCircleIcon class="h-4 w-4 shrink-0" />
                <span>No publish blockers detected.</span>
              </div>
            </div>

            <div
              v-if="triggerImpact"
              class="rounded-xl border border-base-300/60 bg-base-100/70 p-4"
            >
              <div>
                <h3 class="text-sm font-semibold text-base-content">Trigger impact</h3>
                <p class="mt-1 text-xs text-base-content/60">
                  Active trigger registrations that will change when this version is published.
                </p>
              </div>

              <div class="mt-4 grid grid-cols-2 gap-2 sm:grid-cols-4">
                <div class="rounded-xl border border-success/20 bg-success/5 px-3 py-2">
                  <div class="text-[11px] uppercase tracking-[0.12em] text-base-content/45">Added</div>
                  <div class="mt-1 text-lg font-semibold text-success">{{ impactCounts.added }}</div>
                </div>
                <div class="rounded-xl border border-warning/20 bg-warning/5 px-3 py-2">
                  <div class="text-[11px] uppercase tracking-[0.12em] text-base-content/45">Updated</div>
                  <div class="mt-1 text-lg font-semibold text-warning">{{ impactCounts.updated }}</div>
                </div>
                <div class="rounded-xl border border-error/20 bg-error/5 px-3 py-2">
                  <div class="text-[11px] uppercase tracking-[0.12em] text-base-content/45">Removed</div>
                  <div class="mt-1 text-lg font-semibold text-error">{{ impactCounts.removed }}</div>
                </div>
                <div class="rounded-xl border border-base-300/60 bg-base-200/40 px-3 py-2">
                  <div class="text-[11px] uppercase tracking-[0.12em] text-base-content/45">Unchanged</div>
                  <div class="mt-1 text-lg font-semibold text-base-content">{{ impactCounts.unchanged }}</div>
                </div>
              </div>

              <div v-if="impactDetails.length > 0" class="mt-4 space-y-2">
                <div
                  v-for="detail in impactDetails"
                  :key="detail.id"
                  class="rounded-xl border px-3 py-2 text-sm"
                  :class="
                    detail.tone === 'success'
                      ? 'border-success/20 bg-success/5 text-base-content'
                      : detail.tone === 'warning'
                      ? 'border-warning/20 bg-warning/5 text-base-content'
                      : 'border-error/20 bg-error/5 text-base-content'
                  "
                >
                  {{ detail.label }}
                </div>
              </div>
            </div>

            <!-- Error Message -->
            <div v-if="publishError" class="alert alert-error">
              <ExclamationTriangleIcon class="h-5 w-5" />
              <span>{{ publishError }}</span>
            </div>

            <!-- Info -->
            <div class="bg-base-200/50 rounded-xl p-4">
              <div class="flex gap-3">
                <CheckCircleIcon class="text-success h-5 w-5 shrink-0" />
                <div class="text-sm">
                  <p class="text-base-content/70">
                    Publishing creates an immutable workflow version. Active triggers will be synced to match the published draft.
                  </p>
                </div>
              </div>
            </div>
          </div>

          <!-- Footer -->
          <div class="border-base-200 flex justify-end gap-3 border-t px-6 py-4">
            <button
              class="btn btn-ghost"
              :disabled="isPublishing"
              @click="handleClose"
            >
              Cancel
            </button>
            <button
              class="btn btn-primary gap-2"
              :disabled="!canPublish"
              @click="handlePublish"
            >
              <span v-if="isPublishing" class="loading loading-spinner loading-sm" />
              <span v-else-if="isValidating" class="loading loading-spinner loading-sm" />
              <RocketLaunchIcon v-else class="h-4 w-4" />
              {{ publishButtonLabel }}
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.2s ease;
}

.modal-enter-active .relative,
.modal-leave-active .relative {
  transition: transform 0.2s ease, opacity 0.2s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-from .relative,
.modal-leave-to .relative {
  transform: scale(0.95);
  opacity: 0;
}
</style>
