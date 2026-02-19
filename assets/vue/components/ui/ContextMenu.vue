<script setup lang="ts">
import { ref, computed, onMounted, onUnmounted, type Component } from 'vue';

export interface MenuItem {
  id: string;
  label: string;
  icon?: Component;
  shortcut?: string;
  danger?: boolean;
  disabled?: boolean;
  divider?: boolean;
}

interface Props {
  x: number;
  y: number;
  show: boolean;
  items: MenuItem[];
}

const props = defineProps<Props>();
const emit = defineEmits<{
  select: [id: string];
  close: [];
}>();

const menuRef = ref<HTMLElement>();

// Adjust position to keep menu in viewport
const adjustedPosition = computed(() => {
  if (!props.show) return { x: props.x, y: props.y };

  const menuWidth = 200;
  const menuHeight = props.items.length * 36 + 16;
  const padding = 8;

  let x = props.x;
  let y = props.y;

  if (x + menuWidth + padding > window.innerWidth) {
    x = window.innerWidth - menuWidth - padding;
  }

  if (y + menuHeight + padding > window.innerHeight) {
    y = window.innerHeight - menuHeight - padding;
  }

  return { x: Math.max(padding, x), y: Math.max(padding, y) };
});

const handleSelect = (item: MenuItem) => {
  if (item.disabled || item.divider) return;
  emit('select', item.id);
  emit('close');
};

const handleClickOutside = (e: MouseEvent) => {
  if (menuRef.value && !menuRef.value.contains(e.target as Node)) {
    emit('close');
  }
};

const handleKeydown = (e: KeyboardEvent) => {
  if (e.key === 'Escape') {
    emit('close');
  }
};

onMounted(() => {
  document.addEventListener('mousedown', handleClickOutside);
  document.addEventListener('keydown', handleKeydown);
});

onUnmounted(() => {
  document.removeEventListener('mousedown', handleClickOutside);
  document.removeEventListener('keydown', handleKeydown);
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
        ref="menuRef"
        class="bg-base-100 border-base-300 fixed z-[1100] min-w-[180px] rounded-xl border py-1.5 shadow-xl"
        :style="{ left: `${adjustedPosition.x}px`, top: `${adjustedPosition.y}px` }"
      >
        <template v-for="item in items" :key="item.id">
          <!-- Divider -->
          <div v-if="item.divider" class="border-base-300 mx-2 my-1.5 border-t" />

          <!-- Menu Item -->
          <button
            v-else
            class="flex w-full items-center gap-3 px-3 py-2 text-sm transition-colors"
            :class="[
              item.disabled
                ? 'text-base-content/30 cursor-not-allowed'
                : item.danger
                  ? 'text-error hover:bg-error/10'
                  : 'text-base-content/80 hover:bg-base-200 hover:text-base-content',
            ]"
            :disabled="item.disabled"
            @click="handleSelect(item)"
          >
            <component
              v-if="item.icon"
              :is="item.icon"
              class="h-4 w-4 shrink-0"
              :class="item.danger ? 'text-error' : 'text-base-content/50'"
            />
            <span class="flex-1 text-left font-medium">{{ item.label }}</span>
            <span v-if="item.shortcut" class="text-base-content/40 font-mono text-xs">
              {{ item.shortcut }}
            </span>
          </button>
        </template>
      </div>
    </Transition>
  </Teleport>
</template>
