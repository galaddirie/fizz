<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import {
  RocketLaunchIcon,
  XMarkIcon,
  CheckCircleIcon,
  ExclamationTriangleIcon,
} from '@heroicons/vue/24/outline';

// =============================================================================
// Props & Emits
// =============================================================================

interface Props {
  isOpen: boolean;
  workflowName?: string;
  currentVersionTag?: string | null;
  isPublishing?: boolean;
  publishError?: string | null;
}

const props = withDefaults(defineProps<Props>(), {
  workflowName: 'Workflow',
  currentVersionTag: null,
  isPublishing: false,
  publishError: null,
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

// =============================================================================
// Handlers
// =============================================================================

function handlePublish() {
  if (!isFormValid.value || props.isPublishing) return;
  
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
                :disabled="isPublishing"
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
                :disabled="isPublishing"
              />
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
              :disabled="!isFormValid || isPublishing"
              @click="handlePublish"
            >
              <span v-if="isPublishing" class="loading loading-spinner loading-sm" />
              <RocketLaunchIcon v-else class="h-4 w-4" />
              {{ isPublishing ? 'Publishing...' : 'Publish' }}
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
