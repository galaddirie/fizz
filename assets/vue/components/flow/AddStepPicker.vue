<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref, watch } from "vue";
import type { NodeLibraryItem } from "@/types/workflow";
import { getStepIcon, isImageIcon } from "@/lib/stepIcons";
import { useThemeStore } from "@/stores/theme";
import { MagnifyingGlassIcon } from "@heroicons/vue/24/outline";

interface Props {
  show: boolean;
  x: number;
  y: number;
  items: NodeLibraryItem[];
}

const props = defineProps<Props>();
const emit = defineEmits<{
  select: [typeId: string];
  close: [];
}>();

const pickerRef = ref<HTMLElement>();
const searchInputRef = ref<HTMLInputElement>();
const listRef = ref<HTMLElement>();
const searchQuery = ref("");
const highlightedIndex = ref(0);

const themeStore = useThemeStore();

const kindStyles = computed(() => ({
  trigger: "text-primary",
  action: "text-info",
  transform: themeStore.theme === "dark" ? "text-secondary" : "text-info",
  control_flow: "text-warning",
}));

const filteredItems = computed(() => {
  const query = searchQuery.value.trim().toLowerCase();
  if (!query) return props.items;

  return props.items.filter(
    (item) =>
      item.name.toLowerCase().includes(query) ||
      item.description.toLowerCase().includes(query) ||
      item.type_id.toLowerCase().includes(query)
  );
});

const groupedItems = computed(() => {
  const map = new Map<string, NodeLibraryItem[]>();

  for (const item of filteredItems.value) {
    let group = map.get(item.category);
    if (!group) {
      group = [];
      map.set(item.category, group);
    }
    group.push(item);
  }

  Array.from(map.values()).forEach((items) => {
    items.sort((a: NodeLibraryItem, b: NodeLibraryItem) =>
      a.name.localeCompare(b.name)
    );
  });

  return Array.from(map.entries())
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([category, items]) => ({ category, items }));
});

const flatItems = computed(() => {
  return groupedItems.value.flatMap((g) => g.items);
});

const adjustedPosition = computed(() => {
  if (!props.show || typeof window === "undefined") {
    return { x: props.x, y: props.y };
  }

  const panelWidth = 280;
  const headerHeight = 56;
  const rowHeight = 52;
  const categoryHeaderHeight = 28;
  const categoryCount = groupedItems.value.length;
  const itemCount = Math.min(flatItems.value.length, 7);
  const estimatedHeight =
    headerHeight +
    itemCount * rowHeight +
    categoryCount * categoryHeaderHeight +
    40;
  const padding = 8;

  let x = props.x;
  let y = props.y;

  if (x + panelWidth + padding > window.innerWidth) {
    x = window.innerWidth - panelWidth - padding;
  }

  if (y + estimatedHeight + padding > window.innerHeight) {
    y = window.innerHeight - estimatedHeight - padding;
  }

  return { x: Math.max(padding, x), y: Math.max(padding, y) };
});

watch(
  () => props.show,
  async (show) => {
    if (!show) return;
    searchQuery.value = "";
    highlightedIndex.value = 0;
    await nextTick();
    searchInputRef.value?.focus();
  }
);

watch(flatItems, (items) => {
  if (items.length === 0) {
    highlightedIndex.value = -1;
    return;
  }

  if (highlightedIndex.value < 0 || highlightedIndex.value >= items.length) {
    highlightedIndex.value = 0;
  }
});

const scrollHighlightedIntoView = () => {
  if (!listRef.value) return;
  const el = listRef.value.querySelector('[data-highlighted="true"]');
  if (el) {
    el.scrollIntoView({ block: "nearest" });
  }
};

const closePicker = () => emit("close");

const selectStep = (item?: NodeLibraryItem) => {
  if (!item) return;
  emit("select", item.type_id);
  emit("close");
};

const handleClickOutside = (event: MouseEvent) => {
  if (!props.show) return;
  if (pickerRef.value && !pickerRef.value.contains(event.target as Node)) {
    closePicker();
  }
};

const handleKeydown = (event: KeyboardEvent) => {
  if (!props.show) return;
  if (event.key === "Escape") {
    event.preventDefault();
    closePicker();
    return;
  }

  const items = flatItems.value;
  if (items.length === 0) return;

  if (event.key === "ArrowDown") {
    event.preventDefault();
    highlightedIndex.value = (highlightedIndex.value + 1) % items.length;
    nextTick(scrollHighlightedIntoView);
    return;
  }

  if (event.key === "ArrowUp") {
    event.preventDefault();
    highlightedIndex.value =
      (highlightedIndex.value - 1 + items.length) % items.length;
    nextTick(scrollHighlightedIntoView);
    return;
  }

  if (event.key === "Enter") {
    event.preventDefault();
    selectStep(items[highlightedIndex.value]);
  }
};

const flatIndexOf = (item: NodeLibraryItem) => flatItems.value.indexOf(item);

const kindClass = (item: NodeLibraryItem) =>
  kindStyles.value[item.step_kind] ?? "";

onMounted(() => {
  document.addEventListener("mousedown", handleClickOutside);
  document.addEventListener("keydown", handleKeydown);
});

onUnmounted(() => {
  document.removeEventListener("mousedown", handleClickOutside);
  document.removeEventListener("keydown", handleKeydown);
});
</script>

<template>
  <Teleport to="body">
    <Transition
      enter-active-class="transition duration-100 ease-out"
      enter-from-class="opacity-0 scale-95"
      enter-to-class="opacity-100 scale-100"
      leave-active-class="transition duration-75 ease-in"
      leave-from-class="opacity-100 scale-100"
      leave-to-class="opacity-0 scale-95"
    >
      <div
        v-if="show"
        ref="pickerRef"
        class="bg-base-100 border-base-300 fixed z-[1150] w-[280px] max-w-[calc(100vw-16px)] overflow-hidden rounded-xl border shadow-xl"
        :style="{
          left: `${adjustedPosition.x}px`,
          top: `${adjustedPosition.y}px`,
        }"
      >
        <div class="p-2 pb-0">
          <div class="group relative">
            <MagnifyingGlassIcon
              class="text-base-content/30 group-focus-within:text-primary absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2 transition-colors"
            />
            <input
              ref="searchInputRef"
              v-model="searchQuery"
              type="text"
              placeholder="Search steps..."
              class="bg-base-200/40 focus:border-primary/20 focus:bg-base-100 focus:ring-primary/5 placeholder:text-base-content/30 w-full rounded-lg border border-transparent py-2 pr-3 pl-9 text-sm outline-none transition-all duration-200 focus:ring-4"
            />
          </div>
        </div>

        <div
          ref="listRef"
          class="custom-scrollbar max-h-[360px] overflow-y-auto p-2"
        >
          <template v-for="group in groupedItems" :key="group.category">
            <div
              class="text-base-content/40 mt-2 mb-1 px-2 text-[11px] font-semibold tracking-wider uppercase first:mt-0"
            >
              {{ group.category }}
            </div>

            <button
              v-for="item in group.items"
              :key="item.type_id"
              type="button"
              class="group flex w-full items-start gap-2.5 rounded-lg px-2 py-1.5 text-left transition-colors duration-100"
              :class="flatIndexOf(item) === highlightedIndex && 'bg-primary/10'"
              :data-highlighted="flatIndexOf(item) === highlightedIndex"
              @mouseenter="highlightedIndex = flatIndexOf(item)"
              @click="selectStep(item)"
            >
              <div
                class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border transition-colors duration-150"
                :class="[
                  kindClass(item),
                  flatIndexOf(item) === highlightedIndex
                    ? 'bg-primary/10 border-primary/20'
                    : 'bg-base-200/50 border-base-200/50',
                ]"
              >
                <img
                  v-if="isImageIcon(item.icon)"
                  :src="item.icon"
                  alt=""
                  class="h-4 w-4 object-contain"
                />
                <component
                  v-else
                  :is="getStepIcon(item.icon)"
                  class="h-4 w-4"
                />
              </div>
              <div class="min-w-0 flex-1 py-0.5">
                <span
                  class="text-base-content/90 block truncate text-sm font-medium leading-tight"
                  >{{ item.name }}</span
                >
                <span
                  class="text-base-content/40 block truncate text-xs leading-snug"
                  >{{ item.description }}</span
                >
              </div>
            </button>
          </template>

          <div
            v-if="flatItems.length === 0"
            class="flex flex-col items-center justify-center py-8 text-center"
          >
            <MagnifyingGlassIcon class="text-base-content/20 mb-2 h-6 w-6" />
            <p class="text-base-content/40 text-sm">No matching steps</p>
          </div>
        </div>

        <div class="border-base-200 border-t px-3 py-1.5">
          <div
            class="text-base-content/30 flex items-center justify-between text-[11px]"
          >
            <span>
              <kbd
                class="bg-base-200/60 rounded px-1 py-0.5 font-mono text-[10px]"
                >&uarr;&darr;</kbd
              >
              navigate
            </span>
            <span>
              <kbd
                class="bg-base-200/60 rounded px-1 py-0.5 font-mono text-[10px]"
                >&crarr;</kbd
              >
              select
            </span>
            <span>
              <kbd
                class="bg-base-200/60 rounded px-1 py-0.5 font-mono text-[10px]"
                >esc</kbd
              >
              close
            </span>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
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
</style>
