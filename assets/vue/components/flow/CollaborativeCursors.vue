<script setup lang="ts">
import { computed, ref, watch, onMounted } from 'vue';
import type { UserPresence } from '@/types/workflow';
import { generateColor } from '@/lib/color';
import { useLiveVue } from 'live_vue';

const props = defineProps<{
  presences: UserPresence[];
  currentUserId?: string;
  zoom?: number;
}>();

// Use local state for presences to allow fast updates via events
// independent of the slower prop update cycle
// Initialize with props data
const localPresences = ref<UserPresence[]>(props.presences);

// Sync with props when they change (initial load or full updates)
// This ensures consistency if the server pushes a full update via assigns
watch(
  () => props.presences,
  newVal => {
    localPresences.value = newVal;
  }
);

const live = useLiveVue();

onMounted(() => {
  // Listen for fast cursor updates bypassing the DOM prop cycle
  live.handleEvent('presence_update', (payload: unknown) => {
    if (!payload || typeof payload !== 'object') return;
    const data = payload as { presences?: UserPresence[] };
    if (Array.isArray(data.presences)) {
      localPresences.value = data.presences;
    }
  });
});

// Filter out current user and users without valid cursor positions
const visibleCursors = computed(() => {
  return localPresences.value.filter(p => {
    // Skip current user
    if (p.user.id === props.currentUserId) return false;

    // Skip users without cursor data
    if (!p.cursor) return false;

    // Skip invalid coordinates
    if (typeof p.cursor.x !== 'number' || typeof p.cursor.y !== 'number') return false;
    if (isNaN(p.cursor.x) || isNaN(p.cursor.y)) return false;

    return true;
  });
});

const getCursorColor = (user: UserPresence['user']) => {
  const name = user.name || user.email || user.id;
  return generateColor(name, 0);
};

// Style for positioning cursor in flow coordinates
// The parent container (viewport-top slot) handles the transform
const getCursorStyle = (presence: UserPresence) => {
  if (!presence.cursor) return { display: 'none' };

  const zoom = props.zoom || 1;
  const inverseZoom = 1 / zoom;

  return {
    // Position the tip of the arrow at the cursor position
    transform: `translate(${presence.cursor.x}px, ${presence.cursor.y}px) scale(${inverseZoom})`,
    // Smooth cursor movement with short transition
    // We include the scale in transition to keep it smooth if zoom changes
    transition: 'transform 100ms ease-out',
    willChange: 'transform',
    transformOrigin: '0 0',
  };
};

const getUserDisplayName = (user: UserPresence['user']) => {
  if (user.name) return user.name;
  if (user.email) {
    // Show first part of email
    const [local] = user.email.split('@');
    return local;
  }
  return 'Anonymous';
};
</script>

<template>
  <div
    class="collaborative-cursors pointer-events-none absolute top-0 left-0 h-0 w-0 overflow-visible"
  >
    <TransitionGroup name="cursor">
      <div
        v-for="presence in visibleCursors"
        :key="presence.user.id"
        class="cursor-container absolute top-0 left-0 flex flex-col items-start will-change-transform"
        :style="getCursorStyle(presence)"
      >
        <!-- Cursor Arrow -->
        <svg
          width="18"
          height="18"
          viewBox="0 0 24 24"
          fill="none"
          xmlns="http://www.w3.org/2000/svg"
          class="drop-shadow-[0_2px_2px_rgba(0,0,0,0.4)]"
        >
          <path
            d="M20.5056 10.7754C21.1225 10.5355 21.431 10.4155 21.5176 10.2459C21.5926 10.099 21.5903 9.92446 21.5115 9.77954C21.4205 9.61226 21.109 9.50044 20.486 9.2768L4.59629 3.5728C4.0866 3.38983 3.83175 3.29835 3.66514 3.35605C3.52029 3.40621 3.40645 3.52004 3.35629 3.6649C3.29859 3.8315 3.39008 4.08635 3.57304 4.59605L9.277 20.4858C9.50064 21.1088 9.61246 21.4203 9.77973 21.5113C9.92465 21.5901 10.0991 21.5924 10.2461 21.5174C10.4157 21.4308 10.5356 21.1223 10.7756 20.5054L13.3724 13.8278C13.4194 13.707 13.4429 13.6466 13.4792 13.5957C13.5114 13.5506 13.5508 13.5112 13.5959 13.479C13.6468 13.4427 13.7072 13.4192 13.828 13.3722L20.5056 10.7754Z"
            :fill="getCursorColor(presence.user)"
            :stroke="getCursorColor(presence.user)"
            stroke-width="2"
            stroke-linecap="round"
            stroke-linejoin="round"
          />
        </svg>

        <!-- User name label underneath/offset -->
        <div
          class="cursor-label translate-x-4 -translate-y-1.5 rounded-sm rounded-tl-none px-1.5 py-0.5 text-[10px] font-extrabold tracking-wider whitespace-nowrap text-white uppercase shadow-md"
          :style="{ backgroundColor: getCursorColor(presence.user) }"
        >
          {{ getUserDisplayName(presence.user) }}
        </div>
      </div>
    </TransitionGroup>
  </div>
</template>

<style scoped>
.collaborative-cursors {
  z-index: 1000;
}

.cursor-container {
  z-index: 1000;
}

.cursor-label {
  max-width: 150px;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Transition for cursor enter/leave */
.cursor-enter-active {
  transition: opacity 0.2s ease-out;
}

.cursor-leave-active {
  transition: opacity 0.15s ease-in;
}

.cursor-enter-from,
.cursor-leave-to {
  opacity: 0;
}
</style>
