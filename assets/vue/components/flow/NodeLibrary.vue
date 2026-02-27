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
  ChatBubbleLeftRightIcon,
  ChevronRightIcon,
  ChevronDoubleLeftIcon,
} from '@heroicons/vue/24/outline';

// Props
interface Props {
  libraryItems?: NodeLibraryItem[];
  workflowName?: string;
  workflowStatus?: 'draft' | 'active' | 'archived';
  lastSaved?: string;
  isSaving?: boolean;
  hasUnsavedChanges?: boolean;
}

const props = withDefaults(defineProps<Props>(), {
  libraryItems: () => [],
  workflowName: 'Untitled Workflow',
  workflowStatus: 'draft',
  lastSaved: 'Just now',
  isSaving: false,
  hasUnsavedChanges: false,
});

const statusBadge = computed(() => {
  const configs = {
    draft: { class: 'badge-warning', label: 'Draft' },
    active: { class: 'badge-success', label: 'Active' },
    archived: { class: 'badge-ghost', label: 'Archived' },
  };
  return configs[props.workflowStatus];
});

const emit = defineEmits<{
  (e: 'dragStart', type: string, event: DragEvent): void;
  (e: 'resizeStart', event: PointerEvent): void;
  (e: 'toggleCollapse'): void;
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
  'hero-chat-bubble-left-right': ChatBubbleLeftRightIcon,
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

  for (const category of Object.keys(grouped)) {
    grouped[category] = grouped[category].sort((a, b) => {
      return a.name.localeCompare(b.name);
    });
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

const isImageIcon = (iconName?: string) =>
  !!iconName &&
  (iconName.startsWith('/') || /\.(svg|png|jpe?g|webp)$/i.test(iconName));

const getIcon = (iconName?: string) =>
  iconName ? iconMap[iconName] || CodeBracketIcon : CodeBracketIcon;
</script>

<template>
  <aside class="bg-base-100 relative flex h-full w-72 shrink-0 flex-col overflow-hidden">
    <!-- Header -->
    <div class="shrink-0 border-b border-base-200 px-4 py-3.5">
      <div class="flex items-center justify-between gap-2">
        <a href="/workspaces" class="group flex items-center gap-2.5">
          <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 transition-colors duration-200 group-hover:bg-primary/15">
            <svg class="h-4.5 w-4.5 text-primary" viewBox="0 0 1080 700" fill="currentColor">
              <path d="M1041.6,218.5h0c0-101.3-82.1-183.4-183.4-183.4h-332.6c-27.2,0-49.2,22-49.2,49.2v26.5c0,9.9,2,19.6,5.9,28.7l54.4,127.3c25.2,59.2,33.1,125.2-6.5,176.8l-40.9,53.3c-8.4,10.9-12.9,24.3-12.9,38v80.7c0,27.2,22,49.2,49.2,49.2h437.2c43.5,0,78.7-35.2,78.7-78.7v-6.8c0-14.2,7.9-137.2-13.2-174.9-21.1-37.7-95.8,8.6-115.4,8.6s-19.3-46.6-19.3-46.6c81.7,0,147.9-66.2,147.9-147.9ZM830.2,193.9c-1.3-41.1,32.3-74.7,73.4-73.4,37.2,1.2,67.6,31.5,68.8,68.8,1.3,41.1-32.3,74.7-73.4,73.4-37.2-1.2-67.6-31.5-68.8-68.8Z"/>
              <path d="M472.3,443.6l-40.4,52.7c-8.7,11.3-13.4,25.2-13.4,39.5v87.5c0,23-18.6,41.6-41.6,41.6H112.6c-41.8,0-75.7-33.9-75.7-75.7,0,0,99.5-554,187-554h153c23,0,35.6,47.3,43.2,72.4,67.5,225.1,130.8,262,52.2,336Z"/>
            </svg>
          </div>
          <span class="text-base-content text-lg font-bold tracking-tight transition-colors duration-200 group-hover:text-primary">Fizz</span>
        </a>

        <button
          type="button"
          class="btn btn-ghost btn-xs h-8 w-8 p-0 text-base-content/45 hover:bg-base-200/60 hover:text-base-content/75"
          aria-label="Collapse node library panel"
          title="Collapse panel"
          @click="emit('toggleCollapse')"
        >
          <ChevronDoubleLeftIcon class="h-4 w-4" />
        </button>
      </div>
    </div>

    <!-- Step Library Header & Search -->
    <div class="shrink-0 space-y-2.5 px-4 pt-4 pb-2">
      <div class="flex items-center justify-between">
        <h2 class="text-base-content/50 text-[11px] font-semibold tracking-wider uppercase">Step Library</h2>
        <span class="text-base-content/30 text-[11px] font-medium tabular-nums">{{ allStepTypes.length }}</span>
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
          class="bg-base-200/40 focus:border-primary/20 focus:bg-base-100 focus:ring-primary/5 placeholder:text-base-content/30 w-full rounded-lg border border-transparent py-2 pr-4 pl-9 text-sm transition-all duration-200 outline-none focus:ring-4"
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
            class="group flex cursor-grab items-start gap-3 rounded-xl border border-transparent bg-base-100 p-3 transition-all duration-200 hover:bg-base-200/50 hover:border-base-300/50 active:cursor-grabbing"
            draggable="true"
            @dragstart="onDragStart($event, item.type_id)"
          >
            <!-- Icon -->
            <div
              class="bg-base-200/50 group-hover:bg-primary/10 border-base-200/50 group-hover:border-primary/20 flex h-9 w-9 shrink-0 items-center justify-center rounded-lg border transition-all duration-200"
              :class="kindStyles[item.step_kind]"
            >
              <img
                v-if="isImageIcon(item.icon)"
                :src="item.icon"
                alt=""
                class="h-4.5 w-4.5 object-contain"
              />
              <component v-else :is="getIcon(item.icon)" class="h-4.5 w-4.5" />
            </div>

            <!-- Content -->
            <div class="min-w-0 flex-1">
              <span
                class="text-base-content/90 group-hover:text-base-content block truncate text-sm font-medium"
              >
                {{ item.name }}
              </span>
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

    <div
      class="absolute inset-y-0 right-0 z-30 w-3 cursor-col-resize touch-none"
      role="separator"
      aria-label="Resize node library panel"
      aria-orientation="vertical"
      @pointerdown="emit('resizeStart', $event)"
    />
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
