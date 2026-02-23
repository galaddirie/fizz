<script setup lang="ts">
defineProps<{
  show: boolean;
}>();

defineEmits<{
  confirm: [];
  cancel: [];
}>();
</script>

<template>
  <div
    v-if="show"
    class="absolute inset-0 z-[1200] flex items-center justify-center bg-black/40 backdrop-blur-md animate-in fade-in duration-200"
  >
    <div
      class="bg-base-100 border-base-300 w-full max-w-md scale-100 transform rounded-3xl border p-8 shadow-2xl animate-in zoom-in duration-200"
    >
      <div class="mb-6 flex flex-col items-center text-center">
        <div
          class="bg-warning/10 text-warning mb-4 flex h-16 w-16 items-center justify-center rounded-2xl"
        >
          <svg
            xmlns="http://www.w3.org/2000/svg"
            class="h-8 w-8"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
            />
          </svg>
        </div>
        <h3 class="text-xl font-bold">Unsaved Changes</h3>
        <p class="text-base-content/60 mt-2 text-sm">
          You have unsaved changes in this step configuration. Are you sure you want to discard
          them?
        </p>
      </div>
      <div class="grid grid-cols-2 gap-3">
        <button
          class="btn btn-ghost border-base-300 hover:bg-base-200 rounded-xl font-bold"
          @click="$emit('cancel')"
        >
          Keep Editing
        </button>
        <button
          class="btn btn-error rounded-xl font-bold shadow-lg shadow-error/20"
          @click="$emit('confirm')"
        >
          Discard Changes
        </button>
      </div>
    </div>
  </div>
</template>
