<script setup lang="ts">
import { ref, computed } from 'vue';
import { useThemeStore } from '@/stores/theme';
import type { NodeLibraryItem } from '@/types/workflow';
import {
  MagnifyingGlassIcon,
  CursorArrowRaysIcon,
  BoltIcon,
  ClockIcon,
  GlobeAltIcon,
  EnvelopeIcon,
  CircleStackIcon,
  CodeBracketIcon,
  ArrowPathIcon,
  VariableIcon,
  FunnelIcon,
  AdjustmentsHorizontalIcon,
  ArrowsPointingOutIcon,
  ArrowsPointingInIcon,
  ArrowsRightLeftIcon,
  ListBulletIcon,
  BugAntIcon,
  CalculatorIcon,
  DocumentTextIcon,
  ArrowDownTrayIcon,
  ChevronRightIcon,
} from '@heroicons/vue/24/outline';

// Props - will receive library items from LiveView
interface Props {
  libraryItems?: NodeLibraryItem[];
}

const props = withDefaults(defineProps<Props>(), {
  libraryItems: () => [],
});

const emit = defineEmits<{
  (e: 'dragStart', type: string, event: DragEvent): void;
}>();

const searchQuery = ref('');
const expandedCategories = ref<Set<string>>(new Set(['Triggers', 'Integrations']));

// Icon mapping for step types
const iconMap: Record<string, typeof CursorArrowRaysIcon> = {
  'hero-cursor-arrow-rays': CursorArrowRaysIcon,
  'hero-bolt': BoltIcon,
  'hero-clock': ClockIcon,
  'hero-globe-alt': GlobeAltIcon,
  'hero-envelope': EnvelopeIcon,
  'hero-circle-stack': CircleStackIcon,
  'hero-code-bracket': CodeBracketIcon,
  'hero-arrow-path': ArrowPathIcon,
  'hero-variable': VariableIcon,
  'hero-funnel': FunnelIcon,
  'hero-adjustments-horizontal': AdjustmentsHorizontalIcon,
  'hero-arrows-pointing-out': ArrowsPointingOutIcon,
  'hero-arrows-pointing-in': ArrowsPointingInIcon,
  'hero-arrows-right-left': ArrowsRightLeftIcon,
  'hero-list-bullet': ListBulletIcon,
  'hero-bug-ant': BugAntIcon,
  'hero-calculator': CalculatorIcon,
  'hero-document-text': DocumentTextIcon,
  'hero-arrow-down-tray': ArrowDownTrayIcon,
};

const allStepTypes = computed(() => {
  return props.libraryItems;
});

// Group by category
const categorizedTypes = computed(() => {
  const filtered = allStepTypes.value.filter(item => {
    if (!searchQuery.value) return true;
    const q = searchQuery.value.toLowerCase();
    return (
      item.name.toLowerCase().includes(q) ||
      item.description.toLowerCase().includes(q) ||
      item.type_id.toLowerCase().includes(q)
    );
  });

  const grouped: Record<string, NodeLibraryItem[]> = {};
  for (const item of filtered) {
    if (!grouped[item.category]) {
      grouped[item.category] = [];
    }
    grouped[item.category].push(item);
  }

  // Sort categories with Triggers first
  const sortOrder = ['Triggers', 'Integrations', 'Control Flow', 'Transform', 'Utilities'];
  return Object.entries(grouped).sort(([a], [b]) => {
    const aIdx = sortOrder.indexOf(a);
    const bIdx = sortOrder.indexOf(b);
    if (aIdx === -1 && bIdx === -1) return a.localeCompare(b);
    if (aIdx === -1) return 1;
    if (bIdx === -1) return -1;
    return aIdx - bIdx;
  });
});

// Theme store
const themeStore = useThemeStore();

// Step kind styling - reactive based on theme
const kindStyles = computed(() => ({
  trigger: 'text-primary',
  action: 'text-info',
  transform: themeStore.theme === 'dark' ? 'text-secondary' : 'text-info',
  control_flow: 'text-warning',
}));

const toggleCategory = (category: string) => {
  if (expandedCategories.value.has(category)) {
    expandedCategories.value.delete(category);
  } else {
    expandedCategories.value.add(category);
  }
};

const onDragStart = (event: DragEvent, typeId: string) => {
  if (event.dataTransfer) {
    event.dataTransfer.setData('application/vueflow', typeId);
    event.dataTransfer.effectAllowed = 'move';
  }
  emit('dragStart', typeId, event);
};

const getIcon = (iconName: string) => iconMap[iconName] || CodeBracketIcon;
</script>

<template>
  <aside class="bg-base-100 border-base-200 flex h-full w-72 flex-col overflow-hidden border-r">
    <!-- Header -->
    <div class="border-base-200 shrink-0 border-b px-5 py-5">
      <div class="mb-4 flex items-center justify-between">
        <h2 class="text-base-content/90 text-sm font-semibold tracking-tight">Step Library</h2>
        <span class="badge badge-ghost badge-sm font-mono">
          {{ allStepTypes.length }}
        </span>
      </div>

      <!-- Search -->
      <div class="group relative">
        <MagnifyingGlassIcon
          class="text-base-content/30 group-focus-within:text-primary absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 transition-colors"
        />
        <input
          v-model="searchQuery"
          type="text"
          placeholder="Search steps..."
          class="bg-base-200/30 focus:border-primary/20 focus:bg-base-100 focus:ring-primary/5 placeholder:text-base-content/30 w-full rounded-xl border border-transparent py-2.5 pr-4 pl-9 text-sm font-medium transition-all duration-200 outline-none focus:ring-4"
        />
      </div>
    </div>

    <!-- Step List -->
    <div class="custom-scrollbar flex-1 space-y-1 overflow-y-auto p-3">
      <div v-for="[category, items] in categorizedTypes" :key="category" class="mb-2">
        <!-- Category Header -->
        <button
          class="text-base-content/50 hover:text-base-content/70 hover:bg-base-200/50 flex w-full items-center justify-between rounded-lg px-2 py-2 text-xs font-bold tracking-wider uppercase transition-colors"
          @click="toggleCategory(category)"
        >
          <span>{{ category }}</span>
          <div class="flex items-center gap-2">
            <span class="badge badge-ghost badge-xs">{{ items.length }}</span>
            <ChevronRightIcon
              class="h-3.5 w-3.5 transition-transform duration-200"
              :class="{ 'rotate-90': expandedCategories.has(category) }"
            />
          </div>
        </button>

        <!-- Category Items -->
        <div v-show="expandedCategories.has(category) || searchQuery.length > 0" class="mt-1 space-y-1">
          <div
            v-for="item in items"
            :key="item.type_id"
            class="group bg-base-100 hover:bg-base-200/50 hover:border-base-300/50 flex cursor-grab items-start gap-3 rounded-xl border border-transparent p-3 transition-all duration-200 active:cursor-grabbing"
            draggable="true"
            @dragstart="onDragStart($event, item.type_id)"
          >
            <!-- Icon -->
            <div
              class="bg-base-200/50 group-hover:bg-primary/10 border-base-200/50 group-hover:border-primary/20 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border transition-all duration-200"
              :class="kindStyles[item.step_kind]"
            >
              <component :is="getIcon(item.icon)" class="h-4.5 w-4.5" />
            </div>

            <!-- Content -->
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2">
                <span
                  class="text-base-content/90 group-hover:text-base-content truncate text-sm font-medium"
                >
                  {{ item.name }}
                </span>
              </div>
              <p class="text-base-content/50 mt-0.5 line-clamp-2 text-xs leading-relaxed">
                {{ item.description }}
              </p>
            </div>
          </div>
        </div>
      </div>

      <!-- Empty State -->
      <div
        v-if="categorizedTypes.length === 0"
        class="flex flex-col items-center justify-center py-8 text-center"
      >
        <MagnifyingGlassIcon class="text-base-content/20 mb-2 h-8 w-8" />
        <p class="text-base-content/50 text-sm">No steps match your search</p>
        <button class="btn btn-ghost btn-xs mt-2" @click="searchQuery = ''">Clear search</button>
      </div>
    </div>

    <!-- Footer -->
    <div class="border-base-200 bg-base-200/10 shrink-0 border-t px-5 py-3">
      <div
        class="text-base-content/40 flex items-center justify-center gap-2 text-xs font-medium tracking-wide"
      >
        <CursorArrowRaysIcon class="h-3.5 w-3.5" />
        <span>Drag to canvas to add</span>
      </div>
    </div>
  </aside>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 4px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 5%, transparent);
  border-radius: 10px;
}

.custom-scrollbar:hover::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
}

.line-clamp-2 {
  display: -webkit-box;
  -webkit-line-clamp: 2;
  line-clamp: 2;
  -webkit-box-orient: vertical;
  overflow: hidden;
}
</style>
