<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  RocketLaunchIcon,
  XMarkIcon,
  CheckCircleIcon,
  ExclamationTriangleIcon,
} from '@heroicons/vue/24/outline';
import type { TriggerImpact, WorkflowValidationError } from '@/types/workflow';

// =============================================================================
// Props & Emits
// =============================================================================

interface Props {
  isOpen: boolean;
  workflowName?: string;
  currentVersionTag?: string | null;
  isPublishing?: boolean;
  isValidating?: boolean;
  publishError?: string | null;
  validationErrors?: WorkflowValidationError[];
  triggerImpact?: TriggerImpact | null;
}

const props = withDefaults(defineProps<Props>(), {
  workflowName: 'Workflow',
  currentVersionTag: null,
  isPublishing: false,
  isValidating: false,
  publishError: null,
  validationErrors: () => [],
  triggerImpact: null,
});

const emit = defineEmits<{
  (e: 'close'): void;
  (e: 'publish', payload: { version_tag: string; changelog: string }): void;
}>();

// =============================================================================
// State
// =============================================================================

const versionTag = ref('');
const changelog = ref('');

// Suggest next version based on current
const suggestedVersion = computed(() => {
  if (!props.currentVersionTag) return '1.0.0';
  
  // Try to parse and increment patch version
  const parts = props.currentVersionTag.split('.');
  if (parts.length === 3) {
    const patch = parseInt(parts[2], 10);
    if (!isNaN(patch)) {
      return `${parts[0]}.${parts[1]}.${patch + 1}`;
    }
  }
  return props.currentVersionTag + '.1';
});

// Reset form when modal opens
watch(() => props.isOpen, (isOpen) => {
  if (isOpen) {
    versionTag.value = suggestedVersion.value;
    changelog.value = '';
  }
});

// =============================================================================
// Computed
// =============================================================================

const isFormValid = computed(() => {
  return versionTag.value.trim().length > 0;
});

const blockingErrors = computed(() =>
  props.validationErrors.filter(error => error.severity !== 'warning')
);

const hasBlockingErrors = computed(() => blockingErrors.value.length > 0);
const hasValidationErrors = computed(() => props.validationErrors.length > 0);

const impactCounts = computed(() => ({
  added: props.triggerImpact?.added.length ?? 0,
  updated: props.triggerImpact?.updated.length ?? 0,
  removed: props.triggerImpact?.removed.length ?? 0,
  unchanged: props.triggerImpact?.unchanged_count ?? 0,
}));

// =============================================================================
// Handlers
// =============================================================================

function handlePublish() {
  if (!isFormValid.value || props.isPublishing || props.isValidating || hasBlockingErrors.value) return;
  
  emit('publish', {
    version_tag: versionTag.value.trim(),
    changelog: changelog.value.trim(),
  });
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
          class="bg-base-100 border-base-200 relative z-10 w-full max-w-md rounded-2xl border shadow-2xl"
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
            <!-- Version Tag Input -->
            <div class="form-control">
              <label class="label">
                <span class="label-text font-medium">Version Tag</span>
                <span class="label-text-alt text-base-content/40">Required</span>
              </label>
              <input
                v-model="versionTag"
                type="text"
                placeholder="e.g., 1.0.0"
                class="input input-bordered w-full"
                :disabled="isPublishing || isValidating"
                @keydown.enter="handlePublish"
              />
              <label v-if="currentVersionTag" class="label">
                <span class="label-text-alt text-base-content/40">
                  Current version: {{ currentVersionTag }}
                </span>
              </label>
            </div>

            <!-- Changelog Input -->
            <div class="form-control">
              <label class="label">
                <span class="label-text font-medium">Changelog</span>
                <span class="label-text-alt text-base-content/40">Optional</span>
              </label>
              <textarea
                v-model="changelog"
                placeholder="Describe what changed in this version..."
                class="textarea textarea-bordered h-24 w-full resize-none"
                :disabled="isPublishing || isValidating"
              />
            </div>

            <div class="rounded-xl border border-base-300/60 bg-base-200/40 p-4">
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
                    Publishing creates an immutable version of your workflow. The workflow will become <strong>active</strong> and any triggers will start processing.
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
              :disabled="!isFormValid || isPublishing || isValidating || hasBlockingErrors"
              @click="handlePublish"
            >
              <span v-if="isPublishing" class="loading loading-spinner loading-sm" />
              <span v-else-if="isValidating" class="loading loading-spinner loading-sm" />
              <RocketLaunchIcon v-else class="h-4 w-4" />
              {{ isPublishing ? 'Publishing...' : isValidating ? 'Validating...' : 'Publish' }}
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
