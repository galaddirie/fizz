<script setup lang="ts">
import type { UndoEntrySummary } from '@/stores/undoStore';

interface Props {
  workflowName: string;
  workflowUpdatedAt: string;
  currentVersionTag?: string;
  isCurrentDraft: boolean;
  undoStack: UndoEntrySummary[];
  versions: Array<{ id: string; version_tag: string; published_at?: string | null }>;
  formatRevisionTimestamp: (value?: string | null) => string;
  isSelectedUndo: (entry: { depth: number }) => boolean;
  isSelectedVersion: (version: { id: string }) => boolean;
}

defineProps<Props>();

defineEmits<{
  (event: 'select-current'): void;
  (event: 'select-undo', depth: number): void;
  (event: 'select-version', id: string): void;
}>();
</script>

<template>
  <aside class="bg-base-100 relative flex h-full w-80 shrink-0 flex-col overflow-y-hidden">
    <div class="shrink-0 border-b border-base-200 px-4 py-3.5">
      <div class="truncate text-sm font-semibold text-base-content">{{ workflowName }}</div>
      <div class="mt-1 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">Revisions</div>
    </div>

    <div class="custom-scrollbar flex-1 space-y-6 overflow-y-auto p-4">
      <section class="space-y-3">
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Current
        </div>
        <button
          class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-3 text-left text-xs transition-all"
          :class="[
            isCurrentDraft
              ? 'border-primary/40 bg-primary/10 text-primary'
              : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
          ]"
          @click="$emit('select-current')"
        >
          <div>
            <div class="text-sm font-semibold text-base-content">Current draft</div>
            <div class="text-[11px] text-base-content/50">
              Last updated {{ formatRevisionTimestamp(workflowUpdatedAt) }}
            </div>
          </div>
          <span v-if="currentVersionTag" class="badge badge-ghost badge-xs">
            v{{ currentVersionTag }}
          </span>
        </button>
      </section>

      <section class="space-y-3">
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Edit history
        </div>
        <div
          v-if="undoStack.length === 0"
          class="rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
        >
          No edits yet.
        </div>
        <div v-else class="space-y-2">
          <button
            v-for="entry in undoStack"
            :key="entry.id"
            class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
            :class="[
              isSelectedUndo(entry)
                ? 'border-primary/40 bg-primary/10 text-primary'
                : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
            ]"
            @click="$emit('select-undo', entry.depth)"
          >
            <div>
              <div class="text-sm font-semibold text-base-content">
                {{ entry.label || 'Untitled change' }}
              </div>
              <div class="text-[11px] text-base-content/50">
                {{ formatRevisionTimestamp(entry.timestamp) }}
              </div>
            </div>
            <span class="text-[10px] uppercase tracking-wide text-base-content/40">
              Undo {{ entry.depth }}
            </span>
          </button>
        </div>
      </section>

      <section class="space-y-3">
        <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
          Published versions
        </div>
        <div
          v-if="versions.length === 0"
          class="rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
        >
          No published versions yet.
        </div>
        <div v-else class="space-y-2">
          <button
            v-for="version in versions"
            :key="version.id"
            class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
            :class="[
              isSelectedVersion(version)
                ? 'border-primary/40 bg-primary/10 text-primary'
                : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
            ]"
            @click="$emit('select-version', version.id)"
          >
            <div>
              <div class="text-sm font-semibold text-base-content">
                v{{ version.version_tag }}
              </div>
              <div class="text-[11px] text-base-content/50">
                {{ formatRevisionTimestamp(version.published_at) }}
              </div>
            </div>
          </button>
        </div>
      </section>
    </div>
  </aside>
</template>

