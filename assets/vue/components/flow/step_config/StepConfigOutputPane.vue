<script setup lang="ts">
import { BookmarkIcon, DocumentDuplicateIcon, BoltIcon } from '@heroicons/vue/24/outline';
import { formatDataForDisplay } from '@/lib/dataUtils';
import { colorMap, oklchToHex } from '@/lib/color';

const props = defineProps<{
  activeStepExecution: any;
  hasPinnedOutput: boolean;
  pinnedOutput: any;
  isMultiItemStep: boolean;
  itemStats: any;
  selectedItemIndex: number | null;
  stepExecutionsForStep: any[];
  canEdit: boolean;
  canPinOutput: boolean;
  nodeId?: string;
}>();

const emit = defineEmits<{
  (e: 'update:selectedItemIndex', value: number | null): void;
  (e: 'copyExpression', sectionId: string, key?: string): void;
  (e: 'pinOutput'): void;
  (e: 'unpinOutput'): void;
}>();
</script>

<template>
  <div class="custom-scrollbar mx-auto h-full max-w-4xl space-y-8 p-4">
    <div v-if="activeStepExecution || hasPinnedOutput" class="space-y-8 pb-20">
      <template v-if="activeStepExecution">
        <!-- Multi-Item Summary Bar -->
        <section v-if="isMultiItemStep && itemStats" class="bg-base-200/50 rounded-2xl p-4">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-4">
              <span class="text-base-content/60 text-sm font-medium">
                {{ itemStats.itemsTotal }} items processed
              </span>
              <div class="flex items-center gap-2 text-xs">
                <span
                  v-if="itemStats.completed > 0"
                  class="text-success flex items-center gap-1"
                >
                  <span class="bg-success inline-block size-2 rounded-full"></span>
                  {{ itemStats.completed }} completed
                </span>
                <span v-if="itemStats.failed > 0" class="text-error flex items-center gap-1">
                  <span class="bg-error inline-block size-2 rounded-full"></span>
                  {{ itemStats.failed }} failed
                </span>
                <span v-if="itemStats.running > 0" class="text-info flex items-center gap-1">
                  <span class="bg-info inline-block size-2 rounded-full"></span>
                  {{ itemStats.running }} running
                </span>
              </div>
            </div>
            <button
              v-if="selectedItemIndex !== null"
              @click="emit('update:selectedItemIndex', null)"
              class="btn btn-xs btn-ghost"
            >
              Show All
            </button>
          </div>

          <!-- Item List -->
          <div class="mt-4 flex flex-wrap gap-2">
            <button
              v-for="se in stepExecutionsForStep"
              :key="se.id"
              @click="emit('update:selectedItemIndex', se.item_index ?? 0)"
              :class="[
                'btn btn-xs gap-1',
                selectedItemIndex === se.item_index ? 'btn-primary' : 'btn-ghost',
                se.status === 'failed' ? 'border-error/50' : '',
                se.status === 'completed' ? 'border-success/30' : '',
              ]"
            >
              <span
                :class="[
                  'inline-block size-2 rounded-full',
                  se.status === 'completed' ? 'bg-success' : '',
                  se.status === 'failed' ? 'bg-error' : '',
                  se.status === 'running' ? 'bg-info animate-pulse' : '',
                  se.status === 'skipped' ? 'bg-base-content/30' : '',
                ]"
              ></span>
              #{{ (se.item_index ?? 0) + 1 }}
            </button>
          </div>
        </section>

        <!-- Item Header (when viewing specific item) -->
        <div
          v-if="isMultiItemStep && selectedItemIndex !== null"
          class="flex items-center gap-2 text-sm"
        >
          <span class="text-base-content/60">Viewing item</span>
          <span class="font-bold">#{{ selectedItemIndex + 1 }}</span>
          <span class="text-base-content/40">of {{ itemStats?.itemsTotal }}</span>
          <span
            :class="[
              'badge badge-sm',
              activeStepExecution.status === 'completed' ? 'badge-success' : '',
              activeStepExecution.status === 'failed' ? 'badge-error' : '',
              activeStepExecution.status === 'running' ? 'badge-info' : '',
            ]"
          >
            {{ activeStepExecution.status }}
          </span>
        </div>

        <section>
          <div class="mb-3 flex items-center justify-between">
            <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
              Input Data
            </h4>
            <button
              @click.stop="emit('copyExpression', 'json')"
              class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
            >
              <DocumentDuplicateIcon class="h-3 w-3" />
              Copy Expression
            </button>
          </div>
          <div
            class="bg-base-300/30 overflow-x-auto rounded-2xl p-4 font-mono text-xs whitespace-pre"
          >
            {{ formatDataForDisplay(activeStepExecution.input_data) }}
          </div>
        </section>

        <section>
          <div class="mb-3 flex items-center justify-between">
            <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
              Output Data
            </h4>
            <div class="flex items-center gap-2">
              <button
                v-if="canEdit && !hasPinnedOutput"
                @click.stop="emit('pinOutput')"
                class="btn btn-secondary btn-xs gap-1.5 text-[10px] capitalize shadow-sm transition-all shadow-secondary/20"
                :disabled="!canPinOutput"
                :title="
                  canPinOutput
                    ? 'Pin this output for previews'
                    : 'Run the workflow to capture output before pinning'
                "
              >
                <BookmarkIcon class="h-3 w-3" />
                Pin Output
              </button>

              <button
                v-if="canEdit && hasPinnedOutput"
                @click.stop="emit('unpinOutput')"
                class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize text-error/60 hover:text-error hover:bg-error/10"
              >
                Unpin
              </button>

              <button
                @click.stop="emit('copyExpression', 'steps', nodeId)"
                class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
              >
                <DocumentDuplicateIcon class="h-3 w-3" />
                Copy Expression
              </button>
              
              <span v-if="hasPinnedOutput" 
                class="badge badge-sm font-bold tracking-wider uppercase"
                :style="{ 
                  backgroundColor: oklchToHex(colorMap.pinned), 
                  borderColor: oklchToHex(colorMap.pinned),
                  color: 'white'
                }"
              >Pinned</span>
              <span
                v-else-if="activeStepExecution?.status === 'completed'"
                class="badge badge-success badge-sm"
                >Success</span
              >
            </div>
          </div>
          <div
            class="overflow-x-auto rounded-2xl border-2 p-4 font-mono text-xs whitespace-pre transition-all duration-300"
            :class="hasPinnedOutput ? 'shadow-lg' : 'bg-base-300/30 border-success/10'"
            :style="hasPinnedOutput ? { 
              borderColor: oklchToHex(colorMap.pinned) + '66', // 40% opacity
              backgroundColor: oklchToHex(colorMap.pinned) + '08', // approx 3% opacity
              boxShadow: `0 10px 15px -3px ${oklchToHex(colorMap.pinned)}0D` // approx 5% opacity shadow
            } : {}"
          >
            {{ formatDataForDisplay(hasPinnedOutput ? pinnedOutput : activeStepExecution.output_data) }}
          </div>
        </section>

        <section v-if="activeStepExecution.error">
          <h4 class="text-error/60 mb-3 text-xs font-bold tracking-widest uppercase">
            Error
          </h4>
          <div
            class="bg-error/5 border-error/20 text-error rounded-2xl border p-4 font-mono text-xs"
          >
            {{ activeStepExecution.error }}
          </div>
        </section>
      </template>
      
      <!-- Case where no execution but has pinned output (show pinned only) -->
      <section v-else-if="hasPinnedOutput">
         <div class="mb-3 flex items-center justify-between">
            <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
              Pinned Output
            </h4>
            <div class="flex items-center gap-2">
              <button
                v-if="canEdit"
                @click.stop="emit('unpinOutput')"
                class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize text-error/60 hover:text-error hover:bg-error/10"
              >
                Unpin
              </button>
              <span v-if="hasPinnedOutput" 
                class="badge badge-sm font-bold tracking-wider uppercase"
                :style="{ 
                  backgroundColor: oklchToHex(colorMap.pinned), 
                  borderColor: oklchToHex(colorMap.pinned),
                  color: 'white'
                }"
              >Pinned</span>
            </div>
          </div>
          <div
            class="overflow-x-auto rounded-2xl border-2 p-4 font-mono text-xs whitespace-pre shadow-lg transition-all duration-300"
            :style="{ 
              borderColor: oklchToHex(colorMap.pinned) + '66', 
              backgroundColor: oklchToHex(colorMap.pinned) + '08',
              boxShadow: `0 10px 15px -3px ${oklchToHex(colorMap.pinned)}0D`
            }"
          >
            {{ formatDataForDisplay(pinnedOutput) }}
          </div>
      </section>
    </div>

    <div v-else class="flex h-full flex-col items-center justify-center opacity-40">
      <BoltIcon class="mb-4 h-16 w-16" />
      <p class="text-sm font-bold">No execution data available</p>
      <p class="text-xs">Run the workflow to see inputs and outputs</p>
    </div>
  </div>
</template>
