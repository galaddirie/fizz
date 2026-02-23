<script setup lang="ts">
import { inject } from 'vue';
import {
  LinkIcon,
  DocumentDuplicateIcon,
  SignalIcon,
  CheckCircleIcon,
} from '@heroicons/vue/24/outline';
import FieldWrapper from '../fields/FieldWrapper.vue';
import ExpressionPreviewError from './ExpressionPreviewError.vue';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;
</script>

<template>
  <div class="mx-auto max-w-3xl space-y-8 pb-20">
    <!-- Header -->
    <div class="space-y-1">
      <h3 class="text-[15px] font-semibold tracking-tight text-base-content">
        {{ state.canEdit.value ? 'Configuration' : 'Inspector' }}
      </h3>
      <p class="text-xs text-base-content/40">
        {{
          state.canEdit.value
            ? 'Set the parameters for this operation.'
            : 'Review configuration and runtime details.'
        }}
      </p>
    </div>

    <!-- Webhook Section -->
    <div
      v-if="state.isWebhookTrigger.value"
      class="space-y-4 rounded-2xl bg-base-100 p-5 ring-1 ring-base-content/[0.04]"
    >
      <div class="flex items-center justify-between">
        <h4 class="flex items-center gap-2 text-[13px] font-semibold text-base-content">
          <LinkIcon class="h-3.5 w-3.5 text-primary" />
          Webhook URL
        </h4>

        <!-- Test / Production segmented toggle -->
        <div role="group" aria-label="Webhook URL mode" class="flex items-center gap-px rounded-lg bg-base-200/50 p-[3px]">
          <button
            class="rounded-md px-2.5 py-1 text-[10px] font-semibold tracking-wide transition-all duration-150"
            :class="[
              state.webhookMode.value === 'test'
                ? 'bg-base-100 text-base-content shadow-sm'
                : 'text-base-content/30 hover:text-base-content/50',
            ]"
            :aria-pressed="state.webhookMode.value === 'test'"
            @click="state.webhookMode.value = 'test'"
          >
            Test
          </button>
          <button
            class="rounded-md px-2.5 py-1 text-[10px] font-semibold tracking-wide transition-all duration-150"
            :class="[
              state.webhookMode.value === 'production'
                ? 'bg-base-100 text-base-content shadow-sm'
                : 'text-base-content/30 hover:text-base-content/50',
            ]"
            :aria-pressed="state.webhookMode.value === 'production'"
            @click="state.webhookMode.value = 'production'"
          >
            Production
          </button>
        </div>
      </div>

      <!-- URL bar -->
      <div class="relative">
        <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3">
          <span
            class="rounded-md px-1.5 py-0.5 font-mono text-[9px] font-bold uppercase tracking-wider"
            :class="[
              state.webhookMode.value === 'test'
                ? 'bg-primary/10 text-primary'
                : 'bg-base-content/8 text-base-content/50',
            ]"
          >{{ state.webhookMethod.value }}</span>
        </div>
        <input
          type="text"
          readonly
          :value="state.webhookUrl.value"
          class="w-full rounded-xl bg-base-200/20 py-2.5 pl-[4.25rem] pr-10 font-mono text-xs text-base-content/60 outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 selection:bg-primary/15 hover:ring-base-content/10"
          @click="($event.target as HTMLInputElement).select()"
        />
        <div class="absolute inset-y-0 right-0 flex items-center pr-2">
          <button
            class="rounded-lg p-1.5 text-base-content/20 transition-colors hover:bg-base-200/50 hover:text-base-content/50"
            aria-label="Copy webhook URL"
            @click="state.copyWebhookUrl()"
          >
            <DocumentDuplicateIcon class="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      <!-- Listen controls (test mode only, edit mode) -->
      <div v-if="state.canEdit.value && state.webhookMode.value === 'test'" class="space-y-3 pt-1">
        <button
          class="flex w-full items-center justify-center gap-2 rounded-xl px-4 py-2.5 text-sm font-medium transition-all duration-200"
          :class="[
            state.isWebhookListening.value
              ? 'bg-error/8 text-error ring-1 ring-error/15 hover:bg-error/12'
              : 'bg-primary text-primary-content shadow-lg shadow-primary/20 hover:shadow-xl hover:shadow-primary/25 hover:brightness-110',
          ]"
          :disabled="state.isWebhookListeningElsewhere.value"
          @click="state.toggleWebhookListening()"
        >
          <SignalIcon
            class="h-4 w-4"
            :class="state.isWebhookListening.value ? '' : 'animate-pulse'"
          />
          {{ state.isWebhookListening.value ? 'Stop listening' : 'Listen for test event' }}
        </button>

        <!-- Status messages -->
        <div
          v-if="state.isWebhookListening.value"
          class="flex items-start gap-2.5 rounded-xl bg-primary/[0.04] px-4 py-3 ring-1 ring-primary/10"
        >
          <div class="mt-0.5 h-1.5 w-1.5 shrink-0 animate-pulse rounded-full bg-primary"></div>
          <p class="text-[11px] leading-relaxed text-base-content/50">
            Listening for test event. Send a
            <span class="font-semibold text-base-content/70">{{ state.webhookMethod.value }}</span>
            request to the Test URL.
          </p>
        </div>
        <div
          v-else-if="state.isWebhookListeningElsewhere.value"
          class="flex items-start gap-2.5 rounded-xl bg-warning/[0.06] px-4 py-3 ring-1 ring-warning/10"
        >
          <div class="mt-0.5 h-1.5 w-1.5 shrink-0 rounded-full bg-warning"></div>
          <p class="text-[11px] leading-relaxed text-base-content/50">
            Another webhook trigger is already listening. Stop it to enable this one.
          </p>
        </div>
      </div>
    </div>

    <!-- Fields -->
    <div class="space-y-3">
      <div v-for="field in state.fields.value" :key="field.key" class="group">
        <div
          class="rounded-2xl transition-all duration-300"
          :class="[
            state.fieldModes.value[field.key] === 'expression' && field.expressionCapable
              ? 'bg-primary/[0.025] ring-1 ring-primary/[0.08]'
              : 'bg-base-100 ring-1 ring-base-content/[0.04] hover:ring-base-content/[0.08]',
          ]"
        >
          <!-- Field header: label + mode control -->
          <div class="flex items-center justify-between px-4 pt-3.5">
            <label class="text-[13px] font-medium tracking-tight text-base-content">
              {{ field.label }}
            </label>

            <!-- Editable mode toggle -->
            <div
              v-if="field.expressionCapable && state.canEdit.value"
              role="group"
              :aria-label="field.label + ' input mode'"
              class="flex items-center gap-px rounded-lg bg-base-200/50 p-[3px]"
            >
              <button
                type="button"
                class="rounded-md px-2.5 py-1 text-[10px] font-semibold tracking-wide transition-all duration-150"
                :class="[
                  state.fieldModes.value[field.key] === 'literal'
                    ? 'bg-base-100 text-base-content shadow-sm'
                    : 'text-base-content/30 hover:text-base-content/50',
                ]"
                :aria-pressed="state.fieldModes.value[field.key] === 'literal'"
                @click="state.setFieldMode(field.key, 'literal')"
              >
                Fixed
              </button>
              <button
                type="button"
                class="rounded-md px-2.5 py-1 text-[10px] font-semibold tracking-wide transition-all duration-150"
                :class="[
                  state.fieldModes.value[field.key] === 'expression'
                    ? 'bg-base-100 text-base-content shadow-sm'
                    : 'text-base-content/30 hover:text-base-content/50',
                ]"
                :aria-pressed="state.fieldModes.value[field.key] === 'expression'"
                @click="state.setFieldMode(field.key, 'expression')"
              >
                Expression
              </button>
            </div>

            <!-- Read-only mode label -->
            <span
              v-else-if="field.expressionCapable"
              class="text-[10px] font-semibold uppercase tracking-wider text-base-content/30"
            >
              {{ state.fieldModes.value[field.key] === 'expression' ? 'Expression' : 'Fixed' }}
            </span>

            <!-- Credential indicator -->
            <span
              v-else
              class="text-[10px] font-semibold uppercase tracking-wider text-base-content/30"
            >
              Credential
            </span>
          </div>

          <!-- Field input -->
          <div class="px-4 pt-2.5 pb-4">
            <FieldWrapper
              :modelValue="state.fieldValues.value[field.key]"
              @update:modelValue="value => state.handleFieldValueUpdate(field.key, value)"
              :mode="state.fieldModes.value[field.key] || 'literal'"
              :field="field"
              :nodeId="state.nodeId.value"
            />

            <!-- Expression preview -->
            <div
              v-if="field.expressionCapable && state.fieldModes.value[field.key] === 'expression'"
              class="mt-3 overflow-hidden rounded-xl bg-base-200/20 ring-1 ring-base-content/[0.04]"
            >
              <div class="flex items-center gap-1.5 px-3 pt-2.5 pb-1.5">
                <div class="h-1 w-1 rounded-full bg-base-content/15"></div>
                <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/25">
                  Preview
                </span>
              </div>

              <!-- Error state -->
              <div
                v-if="state.hasPreviewFor(field.key) && state.previewIsError(state.previewValueFor(field.key))"
                class="px-3 pb-3"
              >
                <ExpressionPreviewError
                  :error="(state.previewValueFor(field.key) as any)"
                />
              </div>

              <!-- Value -->
              <pre
                v-else-if="state.hasPreviewFor(field.key)"
                class="px-3 pb-3 font-mono text-xs leading-relaxed text-base-content/60 whitespace-pre-wrap"
              >{{ state.previewToText(state.previewValueFor(field.key)) }}</pre>

              <!-- Loading -->
              <div
                v-else
                class="flex items-center gap-2 px-3 pb-3 text-xs text-base-content/25"
              >
                <span class="loading loading-dots loading-xs"></span>
                Evaluating&hellip;
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Sub-node Slots -->
    <div
      v-if="state.subnodeSlotRows.value.length > 0"
      class="space-y-4 rounded-2xl bg-base-100 p-5 ring-1 ring-base-content/[0.04]"
    >
      <div>
        <h4 class="text-[13px] font-semibold text-base-content">Sub-node Slots</h4>
        <p class="mt-0.5 text-[11px] text-base-content/35">
          Inputs populated from connected sub-node outputs.
        </p>
      </div>

      <div class="space-y-1.5">
        <div
          v-for="row in state.subnodeSlotRows.value"
          :key="row.slot.id"
          class="flex items-center justify-between gap-4 rounded-xl bg-base-200/15 px-3.5 py-3 ring-1 ring-base-content/[0.03]"
        >
          <div class="flex items-center gap-3 min-w-0">
            <!-- Connection indicator dot -->
            <div
              class="h-2 w-2 shrink-0 rounded-full transition-colors"
              :class="row.isConnected ? 'bg-success' : 'bg-base-content/10'"
            ></div>

            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-xs font-semibold text-base-content">
                  {{ row.slot.title || row.slot.id }}
                </span>
                <span
                  v-if="row.slot.required"
                  class="text-[9px] font-bold uppercase tracking-widest text-warning"
                >
                  req
                </span>
                <span
                  v-if="row.slot.cardinality === 'many'"
                  class="text-[9px] font-medium uppercase tracking-wider text-base-content/25"
                >
                  many
                </span>
              </div>

              <p v-if="row.slot.description" class="mt-0.5 text-[11px] text-base-content/35">
                {{ row.slot.description }}
              </p>

              <p
                v-if="row.isConnected"
                class="mt-0.5 flex items-center gap-1 truncate text-[11px] text-base-content/40"
                :title="row.sourceStepNames.join(', ')"
              >
                <CheckCircleIcon class="h-3 w-3 shrink-0 text-success/70" />
                {{ row.sourceStepNames.join(', ') }}
              </p>
            </div>
          </div>

          <span
            class="shrink-0 text-[10px] font-medium"
            :class="row.isConnected ? 'text-success' : 'text-base-content/20'"
          >
            {{ row.isConnected ? 'Connected' : 'Open' }}
          </span>
        </div>
      </div>

      <!-- Accepts info collapsed below each slot -->
      <div class="border-t border-base-content/[0.04] pt-3">
        <details class="group/accepts">
          <summary class="cursor-pointer text-[10px] font-medium text-base-content/25 transition-colors hover:text-base-content/40">
            Show accepted types
          </summary>
          <div class="mt-2 space-y-1">
            <div
              v-for="row in state.subnodeSlotRows.value"
              :key="'accepts-' + row.slot.id"
              class="flex items-baseline gap-2 text-[11px]"
            >
              <span class="font-medium text-base-content/40">{{ row.slot.title || row.slot.id }}:</span>
              <span class="text-base-content/30">
                {{
                  row.slot.accepts?.type_ids?.length
                    ? row.slot.accepts.type_ids.join(', ')
                    : 'None'
                }}
              </span>
            </div>
          </div>
        </details>
      </div>
    </div>
  </div>
</template>
