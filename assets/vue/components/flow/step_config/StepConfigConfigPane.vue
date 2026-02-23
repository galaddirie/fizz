<script setup lang="ts">
import { LinkIcon, DocumentDuplicateIcon, SignalIcon } from '@heroicons/vue/24/outline';
import FieldWrapper from '../fields/FieldWrapper.vue';
import ExpressionPreviewError from './ExpressionPreviewError.vue';

const props = defineProps<{
  canEdit: boolean;
  isWebhookTrigger: boolean;
  webhookMode: 'test' | 'production';
  webhookMethod: string;
  webhookUrl: string;
  isWebhookListening: boolean;
  isWebhookListeningElsewhere: boolean;
  fields: any[];
  fieldModes: Record<string, 'literal' | 'expression'>;
  fieldValues: Record<string, unknown>;
  subnodeSlotRows: any[];
  nodeId?: string;
  previewIsError: (v: unknown) => boolean;
  previewValueFor: (key: string) => unknown;
  hasPreviewFor: (key: string) => boolean;
  previewToText: (v: unknown) => string;
}>();

const emit = defineEmits<{
  (e: 'update:webhookMode', value: 'test' | 'production'): void;
  (e: 'copyWebhookUrl'): void;
  (e: 'toggleWebhookListening'): void;
  (e: 'setFieldMode', field: string, mode: 'literal' | 'expression'): void;
  (e: 'handleFieldValueUpdate', field: string, value: unknown): void;
}>();
</script>

<template>
  <div class="mx-auto max-w-3xl space-y-10 pb-20">
    <div class="space-y-1">
      <h3 class="text-base-content text-lg font-semibold tracking-tight">
        {{ canEdit ? 'Step Configuration' : 'Step Inspector' }}
      </h3>
      <p class="text-base-content/50 text-xs font-medium">
        {{
          canEdit
            ? 'Configure the parameters for this operation.'
            : 'Review configuration and runtime details for this step.'
        }}
      </p>
    </div>

    <!-- Webhook Specific UI -->
    <div
      v-if="isWebhookTrigger"
      class="bg-base-100 border-base-300 space-y-4 rounded-2xl border p-5 shadow-sm"
    >
      <div class="flex items-center justify-between">
        <h4 class="text-base-content flex items-center gap-2 text-sm font-bold">
          <LinkIcon class="text-primary h-4 w-4" />
          Webhook URLs
        </h4>
        <div class="join bg-base-200/50 rounded-lg p-1">
          <button
            class="join-item btn btn-xs px-3"
            :class="webhookMode === 'test' ? 'btn-primary' : 'btn-ghost'"
            @click="emit('update:webhookMode', 'test')"
          >
            Test URL
          </button>
          <button
            class="join-item btn btn-xs px-3"
            :class="webhookMode === 'production' ? 'btn-neutral' : 'btn-ghost'"
            @click="emit('update:webhookMode', 'production')"
          >
            Production URL
          </button>
        </div>
      </div>

      <div class="relative">
        <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3">
          <span
            class="badge badge-sm font-mono text-[10px]"
            :class="webhookMode === 'test' ? 'badge-primary' : 'badge-neutral'"
            >{{ webhookMethod }}</span
          >
        </div>
        <input
          type="text"
          readonly
          :value="webhookUrl"
          class="input input-sm bg-base-200/30 border-base-300 text-base-content/70 selection:bg-primary/20 w-full pl-16 font-mono text-xs"
          @click="($event.target as HTMLInputElement).select()"
        />
        <div class="absolute inset-y-0 right-0 flex items-center pr-1">
          <button class="btn btn-xs btn-ghost btn-square" @click="emit('copyWebhookUrl')">
            <DocumentDuplicateIcon class="h-4 w-4 opacity-50" />
          </button>
        </div>
      </div>

      <div v-if="canEdit && webhookMode === 'test'" class="space-y-3 pt-2">
        <div class="flex items-center gap-4">
          <button
            class="btn btn-sm w-full gap-2 shadow-lg"
            :class="
              isWebhookListening
                ? 'btn-error shadow-error/20'
                : 'btn-primary shadow-primary/20'
            "
            :disabled="isWebhookListeningElsewhere"
            @click="emit('toggleWebhookListening')"
          >
            <SignalIcon
              class="h-4 w-4"
              :class="isWebhookListening ? '' : 'animate-pulse'"
            />
            {{ isWebhookListening ? 'Stop listening' : 'Listen for test event' }}
          </button>
          <p class="text-base-content/50 flex-1 text-[10px] leading-tight">
            {{
              isWebhookListening
                ? 'Listening for a test request. Send it to the URL to capture payloads.'
                : 'Enable a temporary test listener while editing this draft.'
            }}
          </p>
        </div>

        <div
          v-if="isWebhookListening"
          class="border-primary/20 bg-primary/5 text-base-content/70 rounded-xl border px-4 py-3 text-[11px]"
        >
          Listening for test event. Send a {{ webhookMethod }} request to the Test URL.
        </div>
        <div
          v-else-if="isWebhookListeningElsewhere"
          class="border-warning/20 bg-warning/5 text-base-content/70 rounded-xl border px-4 py-3 text-[11px]"
        >
          Another webhook trigger is already listening. Stop it to enable this one.
        </div>
      </div>
    </div>

    <div class="space-y-6">
      <div v-for="field in fields" :key="field.key" class="group relative">
        <div
          class="rounded-2xl border transition-all duration-300"
          :class="
            fieldModes[field.key] === 'literal' || !field.expressionCapable
              ? 'border-base-300 bg-base-100 shadow-sm'
              : 'border-secondary/20 bg-secondary/[0.02] shadow-inner'
          "
        >
          <div
            class="border-base-200/50 flex items-center justify-between border-b px-5 py-3"
          >
            <label class="text-base-content block text-sm font-medium tracking-tight">{{
              field.label
            }}</label>

            <div v-if="field.expressionCapable && canEdit" class="join">
              <button
                type="button"
                class="join-item btn btn-xs capitalize"
                :class="fieldModes[field.key] === 'literal' ? 'btn-primary' : 'btn-ghost'"
                @click="emit('setFieldMode', field.key, 'literal')"
              >
                Fixed
              </button>
              <button
                type="button"
                class="join-item btn btn-xs capitalize"
                :class="
                  fieldModes[field.key] === 'expression' ? 'btn-secondary' : 'btn-ghost'
                "
                @click="emit('setFieldMode', field.key, 'expression')"
              >
                Expression
              </button>
            </div>
            <div
              v-else-if="field.expressionCapable"
              class="text-base-content/50 rounded-full border border-base-200 px-3 py-1 text-[10px] font-semibold uppercase tracking-wide"
            >
              {{ fieldModes[field.key] === 'expression' ? 'Expression' : 'Fixed' }}
            </div>
            <div
              v-else
              class="text-base-content/50 rounded-full border border-base-200 px-3 py-1 text-[10px] font-semibold uppercase tracking-wide"
            >
              Credential
            </div>
          </div>

          <div class="p-5">
            <FieldWrapper
              :modelValue="fieldValues[field.key]"
              @update:modelValue="value => emit('handleFieldValueUpdate', field.key, value)"
              :mode="fieldModes[field.key] || 'literal'"
              :field="field"
              :nodeId="nodeId || ''"
            />

            <div
              v-if="field.expressionCapable && fieldModes[field.key] === 'expression'"
              class="border-base-200/70 bg-base-200/20 mt-4 space-y-2 rounded-xl border p-3"
            >
              <div
                class="text-base-content/50 text-[10px] font-semibold tracking-wide uppercase"
              >
                Preview
              </div>
              <ExpressionPreviewError
                v-if="hasPreviewFor(field.key) && previewIsError(previewValueFor(field.key))"
                :error="(previewValueFor(field.key) as any)"
              />
              <pre
                v-else-if="hasPreviewFor(field.key)"
                class="text-base-content/80 bg-base-100 border-base-200 overflow-auto rounded-lg border p-2 font-mono text-xs leading-relaxed whitespace-pre-wrap"
              >{{ previewToText(previewValueFor(field.key)) }}</pre>
              <div
                v-else
                class="text-base-content/60 bg-base-100 border-base-200 rounded-lg border p-2 text-xs"
              >
                Evaluating expression...
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <div
      v-if="subnodeSlotRows.length > 0"
      class="bg-base-100 border-base-300 space-y-4 rounded-2xl border p-5 shadow-sm"
    >
      <div>
        <h4 class="text-base-content text-sm font-bold">Sub-node Slots</h4>
        <p class="text-base-content/50 mt-1 text-xs">
          These inputs are populated directly from connected sub-node outputs.
        </p>
      </div>

      <div class="space-y-2">
        <div
          v-for="row in subnodeSlotRows"
          :key="row.slot.id"
          class="border-base-200 bg-base-200/10 flex items-start justify-between gap-4 rounded-xl border px-3 py-2.5"
        >
          <div class="space-y-1">
            <div class="flex items-center gap-2">
              <span class="text-base-content text-xs font-semibold">
                {{ row.slot.title || row.slot.id }}
              </span>
              <span
                class="badge badge-xs"
                :class="row.slot.required ? 'badge-warning' : 'badge-ghost'"
              >
                {{ row.slot.required ? 'required' : 'optional' }}
              </span>
              <span class="badge badge-ghost badge-xs">
                {{ row.slot.cardinality === 'many' ? 'many' : 'one' }}
              </span>
            </div>
            <p v-if="row.slot.description" class="text-base-content/50 text-[11px]">
              {{ row.slot.description }}
            </p>
            <p class="text-base-content/50 text-[11px]">
              Accepts:
              {{
                row.slot.accepts?.type_ids?.length
                  ? row.slot.accepts.type_ids.join(', ')
                  : 'None'
              }}
            </p>
          </div>

          <div class="max-w-[55%] text-right">
            <p
              class="text-[11px] font-semibold"
              :class="row.isConnected ? 'text-success' : 'text-base-content/40'"
            >
              {{ row.isConnected ? 'Connected' : 'Not connected' }}
            </p>
            <p
              v-if="row.isConnected"
              class="text-base-content/60 mt-1 truncate text-[11px]"
              :title="row.sourceStepNames.join(', ')"
            >
              {{ row.sourceStepNames.join(', ') }}
            </p>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
