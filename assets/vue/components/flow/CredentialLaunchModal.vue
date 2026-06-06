<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import { XMarkIcon, RocketLaunchIcon, KeyIcon } from '@heroicons/vue/24/outline';
import { mountWorkOSWidget } from '../../../js/hooks/workos_react_widgets';

type WorkOSWidgetController = {
  update: () => void;
  destroy: () => void;
};

declare global {
  interface HTMLElement {
    __workosWidget?: WorkOSWidgetController;
  }
}

interface Candidate {
  id: string;
  provider?: string;
  provider_label?: string;
  auth_type?: string;
  owner_user_id?: string;
  owner_display_name?: string;
  display_name?: string;
  requires_reauth?: boolean;
  requires_reauthorization?: boolean;
  status?: string;
}

interface Descriptor {
  step_id: string;
  requirement_key: string;
  provider: string;
  auth_type: string;
  candidates: Candidate[];
}

interface Props {
  isOpen: boolean;
  targetStepId: string | null;
  descriptors: Descriptor[];
  widgetToken: string | null;
}

const props = defineProps<Props>();

const emit = defineEmits<{
  (e: 'close'): void;
  (
    e: 'reauth_connected',
    payload: {
      target_step_id: string | null;
    }
  ): void;
  (
    e: 'submit',
    payload: {
      target_step_id: string | null;
      bindings: Array<{
        step_id: string;
        requirement_key: string;
        binding_data: Record<string, unknown>;
      }>;
    }
  ): void;
}>();

const selections = ref<Record<string, string>>({});

const vWorkosWidget = {
  mounted(element: HTMLElement) {
    element.__workosWidget = mountWorkOSWidget(element, {
      defaultWidget: 'scoped-pipes',
      onConnectionSettled: () => {
        emit('reauth_connected', { target_step_id: props.targetStepId });
      },
    });
  },
  updated(element: HTMLElement) {
    element.__workosWidget?.update();
  },
  beforeUnmount(element: HTMLElement) {
    element.__workosWidget?.destroy();
    element.__workosWidget = undefined;
  },
};

watch(
  () => props.descriptors,
  descriptors => {
    const next: Record<string, string> = {};
    for (const d of descriptors) {
      const key = descriptorKey(d);
      const existing = selections.value[key];
      const candidates = usableCandidates(d);
      if (existing && candidates.some(c => c.id === existing)) {
        next[key] = existing;
      } else if (candidates.length === 1 && !descriptorNeedsInlineAuth(d)) {
        next[key] = candidates[0].id;
      }
    }
    selections.value = next;
  },
  { immediate: true }
);

function descriptorKey(d: Descriptor) {
  return `${d.step_id}::${d.requirement_key}`;
}

function descriptorDomId(d: Descriptor) {
  return `run-launch-pipes-${descriptorKey(d).replace(/[^a-zA-Z0-9_-]/g, '-')}`;
}

function candidateRequiresReauth(c: Candidate) {
  return (
    c.requires_reauth === true ||
    c.requires_reauthorization === true ||
    c.status === 'needs_reauthorization' ||
    c.status === 'needs_reauth' ||
    c.status === 'reauthorization_required'
  );
}

function usableCandidates(d: Descriptor) {
  return d.candidates.filter(c => !candidateRequiresReauth(c));
}

function descriptorHasReauthCandidate(d: Descriptor) {
  return d.candidates.some(candidateRequiresReauth);
}

function descriptorNeedsInlineAuth(d: Descriptor) {
  return d.candidates.length === 0 || descriptorHasReauthCandidate(d);
}

const allSelected = computed(() =>
  props.descriptors.every(d => usableCandidates(d).length > 0 && !!selections.value[descriptorKey(d)])
);

const hasMissingCredentials = computed(() =>
  props.descriptors.some(d => d.candidates.length === 0 || descriptorHasReauthCandidate(d))
);

function credentialSummary(d: Descriptor) {
  return d.auth_type ? `${d.provider} (${d.auth_type})` : d.provider;
}

function candidateLabel(c: Candidate) {
  return c.display_name || c.provider_label || c.owner_display_name || c.id;
}

function providerSlugs(d: Descriptor) {
  if (typeof d.provider === 'string' && d.provider.trim() !== '') {
    return [d.provider.trim()];
  }

  return [];
}

function canRenderPipesWidget(d: Descriptor) {
  return props.widgetToken !== null && providerSlugs(d).length > 0;
}

function widgetProps(d: Descriptor) {
  const slugs = providerSlugs(d);

  return JSON.stringify({
    integrationSlugs: slugs,
    integrationSlug: slugs.length === 1 ? slugs[0] : undefined,
  });
}

function reauthMessage(d: Descriptor) {
  return descriptorHasReauthCandidate(d)
    ? 'This credential needs to be reauthorized before the workflow can run.'
    : "You don't have a credential for this requirement yet.";
}

function handleSubmit() {
  if (!allSelected.value || hasMissingCredentials.value) return;

  const bindings = props.descriptors.map(d => {
    const credentialId = selections.value[descriptorKey(d)];
    return {
      step_id: d.step_id,
      requirement_key: d.requirement_key,
      binding_data: { credential_id: credentialId },
    };
  });

  emit('submit', { target_step_id: props.targetStepId, bindings });
}
</script>

<template>
  <Transition
    enter-active-class="transition duration-200 ease-out"
    enter-from-class="opacity-0"
    enter-to-class="opacity-100"
    leave-active-class="transition duration-150 ease-in"
    leave-from-class="opacity-100"
    leave-to-class="opacity-0"
  >
    <div
      v-if="isOpen"
      class="fixed inset-0 z-50 flex items-center justify-center bg-base-300/60 backdrop-blur-sm"
      @click.self="emit('close')"
    >
      <div
        class="w-full max-w-lg overflow-hidden rounded-2xl bg-base-100 shadow-2xl ring-1 ring-base-content/10"
      >
        <header class="flex items-start justify-between px-6 py-5">
          <div class="flex items-start gap-3">
            <div
              class="flex h-9 w-9 shrink-0 items-center justify-center rounded-xl bg-primary/10 text-primary"
            >
              <KeyIcon class="h-5 w-5" />
            </div>
            <div>
              <h2 class="text-base font-semibold text-base-content">Bind your credentials</h2>
              <p class="mt-0.5 text-[12px] leading-relaxed text-base-content/60">
                This workflow needs your credentials to run. Pick one for each requirement. We'll
                remember your choice for next time.
              </p>
            </div>
          </div>
          <button
            type="button"
            class="rounded-lg p-1 text-base-content/40 transition hover:bg-base-200/40 hover:text-base-content"
            @click="emit('close')"
          >
            <XMarkIcon class="h-5 w-5" />
          </button>
        </header>

        <div class="space-y-4 border-t border-base-content/[0.06] px-6 py-5">
          <div
            v-for="d in descriptors"
            :key="descriptorKey(d)"
            class="rounded-xl bg-base-200/30 px-4 py-3 ring-1 ring-base-content/[0.06]"
          >
            <div class="flex items-center justify-between gap-2">
              <p class="text-[11px] font-medium uppercase tracking-wide text-base-content/50">
                {{ credentialSummary(d) }}
              </p>
              <p class="font-mono text-[11px] text-base-content/40">
                step {{ d.step_id.slice(0, 8) }}
              </p>
            </div>

            <div v-if="usableCandidates(d).length > 0 && !descriptorNeedsInlineAuth(d)" class="mt-2">
              <select
                v-model="selections[descriptorKey(d)]"
                class="w-full rounded-lg bg-base-100 px-3 py-2 text-sm text-base-content ring-1 ring-base-content/10 transition focus:outline-none focus:ring-2 focus:ring-primary/40"
              >
                <option value="" disabled>Select a credential</option>
                <option v-for="c in usableCandidates(d)" :key="c.id" :value="c.id">
                  {{ candidateLabel(c) }}
                </option>
              </select>
            </div>
            <div v-else-if="descriptorNeedsInlineAuth(d) && canRenderPipesWidget(d)" class="mt-3">
              <p class="mb-2 text-[12px] leading-relaxed text-base-content/60">
                {{ reauthMessage(d) }} Connect the required provider below, then this list will
                refresh automatically.
              </p>
              <div
                :id="descriptorDomId(d)"
                v-workos-widget
                phx-hook="WorkOSReactWidget"
                phx-update="ignore"
                data-widget="scoped-pipes"
                :data-auth-token="widgetToken"
                :data-integration-slugs="JSON.stringify(providerSlugs(d))"
                :data-widget-props="widgetProps(d)"
                class="rounded-lg border border-base-content/[0.08] bg-base-100 p-3"
              >
                <div class="flex items-center justify-center py-8 text-sm text-base-content/50">
                  Loading…
                </div>
              </div>
            </div>
            <div
              v-else
              class="mt-2 rounded-lg bg-warning/10 px-3 py-2 text-[12px] leading-relaxed text-warning"
            >
              {{ reauthMessage(d) }} Add or reconnect it in Settings, then come back.
            </div>
          </div>
        </div>

        <footer class="flex items-center justify-end gap-2 border-t border-base-content/[0.06] px-6 py-4">
          <button
            type="button"
            class="rounded-lg px-3 py-1.5 text-sm text-base-content/70 transition hover:bg-base-200/40 hover:text-base-content"
            @click="emit('close')"
          >
            Cancel
          </button>
          <button
            type="button"
            :disabled="!allSelected || hasMissingCredentials"
            class="inline-flex items-center gap-1.5 rounded-lg bg-primary px-3 py-1.5 text-sm font-medium text-primary-content transition disabled:cursor-not-allowed disabled:opacity-40 hover:bg-primary/90"
            @click="handleSubmit"
          >
            <RocketLaunchIcon class="h-4 w-4" />
            Run
          </button>
        </footer>
      </div>
    </div>
  </Transition>
</template>
