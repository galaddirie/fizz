<script setup lang="ts">
import { inject } from 'vue';
import {
  CheckCircleIcon,
} from '@heroicons/vue/24/outline';
import FieldWrapper from '../fields/FieldWrapper.vue';
import ExpressionPreviewError from './ExpressionPreviewError.vue';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;
</script>

<template>
  <div class="mx-auto max-w-3xl pb-20">
    <!-- Header -->
    <div class="mb-6">
      <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/30">
        {{ state.canEdit.value ? 'Configuration' : 'Inspector' }}
      </span>
    </div>

    <!-- Fields -->
    <div class="divide-y divide-base-200/60">
      <div v-for="field in state.fields.value" :key="field.key" class="py-4 first:pt-0">
        <!-- Field header: label + mode control -->
        <div class="flex items-center justify-between">
          <label class="text-[13px] font-medium text-base-content">
            {{ field.label }}
          </label>

          <!-- Editable mode toggle -->
          <div
            v-if="field.expressionCapable && state.canEdit.value"
            role="group"
            :aria-label="field.label + ' input mode'"
            class="flex items-center gap-0.5 rounded-md bg-base-200/40 p-0.5"
          >
            <button
              type="button"
              class="rounded px-2.5 py-1 text-[10px] font-medium transition-all duration-150"
              :class="[
                state.fieldModes.value[field.key] === 'literal'
                  ? 'bg-base-100 text-base-content shadow-sm'
                  : 'text-base-content/40 hover:text-base-content/60',
              ]"
              :aria-pressed="state.fieldModes.value[field.key] === 'literal'"
              @click="state.setFieldMode(field.key, 'literal')"
            >
              Fixed
            </button>
            <button
              type="button"
              class="rounded px-2.5 py-1 text-[10px] font-medium transition-all duration-150"
              :class="[
                state.fieldModes.value[field.key] === 'expression'
                  ? 'bg-base-100 text-base-content shadow-sm'
                  : 'text-base-content/40 hover:text-base-content/60',
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
            class="text-[10px] font-medium uppercase tracking-wider text-base-content/30"
          >
            {{ state.fieldModes.value[field.key] === 'expression' ? 'Expression' : 'Fixed' }}
          </span>

          <!-- Credential indicator -->
          <span
            v-else
            class="text-[10px] font-medium uppercase tracking-wider text-base-content/30"
          >
            Credential
          </span>
        </div>

        <!-- Field input -->
        <div class="mt-3">
          <FieldWrapper
            :modelValue="state.fieldValues.value[field.key]"
            @update:modelValue="value => state.handleFieldValueUpdate(field.key, value)"
            @validation="error => state.handleFieldValidationUpdate(field.key, error)"
            :mode="state.fieldModes.value[field.key] || 'literal'"
            :field="field"
            :nodeId="state.nodeId.value"
          />

          <!-- Expression preview -->
          <div
            v-if="field.expressionCapable && state.fieldModes.value[field.key] === 'expression'"
            class="mt-3 border-t border-base-200/40 pt-3"
          >
            <div class="flex items-center gap-1.5 pb-1.5">
              <div class="h-1 w-1 rounded-full bg-base-content/15"></div>
              <span class="text-[10px] font-medium uppercase tracking-widest text-base-content/25">
                Preview
              </span>
            </div>

            <!-- Error state -->
            <div
              v-if="state.hasPreviewFor(field.key) && state.previewIsError(state.previewValueFor(field.key))"
            >
              <ExpressionPreviewError
                :error="(state.previewValueFor(field.key) as any)"
              />
            </div>

            <!-- Value -->
            <pre
              v-else-if="state.hasPreviewFor(field.key)"
              class="font-mono text-xs leading-relaxed text-base-content/60 whitespace-pre-wrap"
            >{{ state.previewToText(state.previewValueFor(field.key)) }}</pre>

            <!-- Loading -->
            <div
              v-else
              class="flex items-center gap-2 text-xs text-base-content/25"
            >
              <span class="loading loading-dots loading-xs"></span>
              Evaluating&hellip;
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Dependency Inputs -->
    <div
      v-if="state.subnodeInputRows.value.length > 0"
      class="mt-6 border-t border-base-200/60 pt-6"
    >
      <div class="mb-4">
        <span class="text-[10px] font-semibold uppercase tracking-widest text-base-content/30">
          Dependency Inputs
        </span>
        <p class="mt-1 text-[11px] text-base-content/35">
          Inputs populated from connected dependency outputs.
        </p>
      </div>

      <div class="divide-y divide-base-200/40">
        <div
          v-for="row in state.subnodeInputRows.value"
          :key="row.input.id"
          class="flex items-center justify-between gap-4 py-3"
        >
          <div class="flex items-center gap-3 min-w-0">
            <div
              class="h-1.5 w-1.5 shrink-0 rounded-full transition-colors"
              :class="row.isConnected ? 'bg-success' : 'bg-base-content/10'"
            ></div>

            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="text-xs font-medium text-base-content">
                  {{ row.input.title || row.input.id }}
                </span>
                <span
                  v-if="row.input.required"
                  class="text-[9px] font-bold uppercase tracking-widest text-warning"
                >
                  req
                </span>
                <span
                  v-if="row.input.cardinality === 'many'"
                  class="text-[9px] font-medium uppercase tracking-wider text-base-content/25"
                >
                  many
                </span>
              </div>

              <p v-if="row.input.description" class="mt-0.5 text-[11px] text-base-content/35">
                {{ row.input.description }}
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

      <!-- Accepts info -->
      <div class="mt-3 border-t border-base-200/40 pt-3">
        <details class="group/accepts">
          <summary class="cursor-pointer text-[10px] font-medium text-base-content/25 transition-colors hover:text-base-content/40">
            Show accepted types
          </summary>
          <div class="mt-2 space-y-1">
            <div
              v-for="row in state.subnodeInputRows.value"
              :key="'accepts-' + row.input.id"
              class="flex items-baseline gap-2 text-[11px]"
            >
              <span class="font-medium text-base-content/40">{{ row.input.title || row.input.id }}:</span>
              <span class="text-base-content/30">
                {{
                  row.input.accepts?.provides?.length
                    ? row.input.accepts.provides.join(', ')
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
