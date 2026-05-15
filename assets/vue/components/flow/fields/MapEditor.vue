<template>
  <div class="space-y-3">
    <p v-if="field.description" class="text-[11px] leading-relaxed text-base-content/40">
      {{ field.description }}
    </p>

    <div class="rounded-xl border border-base-content/[0.06] bg-base-100/70 shadow-sm">
      <div class="border-b border-base-content/[0.05] px-3 py-2.5">
        <div class="flex flex-wrap items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-2">
            <TableCellsIcon class="h-4 w-4 shrink-0 text-base-content/35" />
            <div class="min-w-0">
              <div class="flex items-center gap-2">
                <span class="truncate text-[12px] font-medium text-base-content/70">
                  {{ selectedTableLabel }}
                </span>
                <span
                  class="rounded-full px-2 py-0.5 text-[10px] font-medium"
                  :class="schemaLocked ? 'bg-primary/10 text-primary' : 'bg-base-200/70 text-base-content/45'"
                >
                  {{ schemaLocked ? 'Schema locked' : 'Freeform' }}
                </span>
              </div>
              <div class="mt-0.5 text-[10px] text-base-content/35">
                {{ sheetStatusLabel }}
              </div>
            </div>
          </div>

          <button
            v-if="canRefreshLookup"
            type="button"
            class="inline-flex h-8 w-8 items-center justify-center rounded-lg text-base-content/40 transition-all duration-150 hover:bg-base-200/70 hover:text-base-content/70 disabled:pointer-events-none disabled:opacity-40"
            :disabled="isRefreshingLookup"
            :aria-label="refreshLabel"
            @click="refreshLookups"
          >
            <ArrowPathIcon
              class="h-4 w-4"
              :class="isRefreshingLookup ? 'animate-spin' : ''"
            />
          </button>
        </div>

        <div class="mt-3 grid gap-2 sm:grid-cols-2">
          <div>
            <label
              class="mb-1 block text-[10px] font-semibold uppercase tracking-wider text-base-content/35"
              :for="sheetSelectId"
            >
              Sheet
            </label>
            <select
              :id="sheetSelectId"
              class="h-9 w-full rounded-lg bg-base-100 px-3 text-sm text-base-content outline-none ring-1 ring-base-content/[0.08] transition-all duration-150 hover:ring-base-content/15 focus:ring-2 focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-50"
              :value="sheetSelectValue"
              :disabled="field.disabled || field.readOnly"
              @change="onSheetSelectionChange(($event.target as HTMLSelectElement).value)"
            >
              <option value="">No sheet</option>
              <option
                v-for="option in sheetSelectOptions"
                :key="option.id"
                :value="option.id"
              >
                {{ option.label }}
              </option>
            </select>
            <p
              v-if="sheetErrorMessage"
              class="mt-1.5 text-[11px] leading-relaxed text-warning/80"
            >
              {{ sheetErrorMessage }}
            </p>
          </div>

          <div>
            <label
              class="mb-1 block text-[10px] font-semibold uppercase tracking-wider text-base-content/35"
              :for="tableSelectId"
            >
              Table
            </label>
            <select
              :id="tableSelectId"
              class="h-9 w-full rounded-lg bg-base-100 px-3 text-sm text-base-content outline-none ring-1 ring-base-content/[0.08] transition-all duration-150 hover:ring-base-content/15 focus:ring-2 focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-50"
              :value="tableSelectValue"
              :disabled="field.disabled || field.readOnly"
              @change="onTableSelectionChange(($event.target as HTMLSelectElement).value)"
            >
              <option value="">No table</option>
              <option
                v-for="option in tableSelectOptions"
                :key="option.id"
                :value="option.id"
              >
                {{ tableOptionLabel(option) }}
              </option>
            </select>
            <p
              v-if="tableErrorMessage"
              class="mt-1.5 text-[11px] leading-relaxed text-warning/80"
            >
              {{ tableErrorMessage }}
            </p>
          </div>
        </div>
      </div>

      <div class="overflow-x-auto">
        <div class="min-w-full p-3">
          <div
            class="grid min-w-max overflow-hidden rounded-lg border border-base-content/[0.06] bg-base-100"
            :style="{ gridTemplateColumns }"
          >
            <div
              v-for="(header, columnIndex) in displayHeaders"
              :key="`header-${columnIndex}-${header}`"
              class="min-w-0 border-b border-r border-base-content/[0.06] bg-base-200/40 px-2 py-2"
            >
              <div
                v-if="schemaLocked"
                class="truncate text-[11px] font-semibold text-base-content/60"
                :title="header"
              >
                {{ header }}
              </div>
              <input
                v-else-if="usesNamedFreeformHeaders"
                :id="headerInputId(columnIndex)"
                type="text"
                class="h-7 w-full rounded-md bg-base-100/80 px-2 text-[11px] font-medium text-base-content/65 outline-none ring-1 ring-base-content/[0.06] transition-all duration-150 placeholder:text-base-content/25 hover:ring-base-content/10 focus:ring-2 focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-40"
                :value="freeformHeaders[columnIndex] ?? ''"
                :placeholder="columnName(columnIndex)"
                :disabled="field.disabled"
                :readonly="field.readOnly"
                @input="onHeaderInput(columnIndex, ($event.target as HTMLInputElement).value)"
              />
              <div
                v-else
                class="truncate text-center text-[11px] font-semibold text-base-content/45"
                :title="columnName(columnIndex)"
              >
                {{ columnName(columnIndex) }}
              </div>
            </div>

            <div class="border-b border-base-content/[0.06] bg-base-200/40 px-2 py-2" />

            <template
              v-for="(row, rowIndex) in gridRows"
              :key="`row-${rowIndex}`"
            >
              <div
                v-for="columnIndex in columnIndexes"
                :key="`cell-${rowIndex}-${columnIndex}`"
                class="min-w-0 border-r border-t border-base-content/[0.05]"
              >
                <input
                  :id="cellInputId(rowIndex, columnIndex)"
                  type="text"
                  class="h-10 w-full bg-transparent px-2.5 text-sm text-base-content outline-none transition-all duration-150 placeholder:text-base-content/25 hover:bg-base-200/25 focus:bg-base-100 focus:ring-2 focus:ring-inset focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-40"
                  :value="row[columnIndex] ?? ''"
                  :placeholder="cellPlaceholder"
                  :disabled="field.disabled"
                  :readonly="field.readOnly"
                  @input="onCellInput(rowIndex, columnIndex, ($event.target as HTMLInputElement).value)"
                />
              </div>

              <div class="flex items-center justify-center border-t border-base-content/[0.05] bg-base-100">
                <button
                  type="button"
                  class="inline-flex h-7 w-7 items-center justify-center rounded-md text-base-content/30 transition-all duration-150 hover:bg-error/10 hover:text-error disabled:pointer-events-none disabled:opacity-30"
                  :disabled="field.disabled || field.readOnly || gridRows.length <= 1"
                  :aria-label="`Remove row ${rowIndex + 1}`"
                  @click="removeRow(rowIndex)"
                >
                  <TrashIcon class="h-3.5 w-3.5" />
                </button>
              </div>
            </template>
          </div>
        </div>
      </div>

      <div class="flex flex-wrap items-center justify-between gap-2 border-t border-base-content/[0.05] px-3 py-2.5">
        <div class="text-[10px] text-base-content/35">
          {{ rowSummary }}
        </div>
        <div class="flex items-center gap-1.5">
          <button
            v-if="!schemaLocked"
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-[11px] font-medium text-base-content/50 transition-all duration-150 hover:bg-base-200/70 hover:text-base-content/70 disabled:pointer-events-none disabled:opacity-40"
            :disabled="field.disabled || field.readOnly"
            @click="addColumn"
          >
            <PlusIcon class="h-3.5 w-3.5" />
            Column
          </button>
          <button
            type="button"
            class="inline-flex items-center gap-1.5 rounded-lg bg-base-200/60 px-2.5 py-1.5 text-[11px] font-medium text-base-content/60 transition-all duration-150 hover:bg-base-200 hover:text-base-content disabled:pointer-events-none disabled:opacity-40"
            :disabled="field.disabled || field.readOnly"
            @click="addRow"
          >
            <PlusIcon class="h-3.5 w-3.5" />
            Row
          </button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, inject, ref, watch } from 'vue';
import { watchDebounced } from '@vueuse/core';
import { useLiveVue } from 'live_vue';
import {
  ArrowPathIcon,
  PlusIcon,
  TableCellsIcon,
  TrashIcon,
} from '@heroicons/vue/24/outline';

import { StepConfigKey } from '../step_config/useStepConfig';
import type { ConfigField } from '@/types/configSchema';

type SheetRow = string[];
type SerializedRow = Record<string, unknown> | unknown[];
type SheetOption = {
  id: string;
  label: string;
};
type TableColumnOption = {
  id: string;
  label: string;
};
type TableOption = {
  id: string;
  label: string;
  sheetName: string;
  sheetId?: number;
  columns: TableColumnOption[];
};

const DEFAULT_COLUMN_COUNT = 3;

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue', 'validation']);

const live = useLiveVue();
const state = inject(StepConfigKey, null);

const sheetOptions = ref<SheetOption[]>([]);
const tableOptions = ref<TableOption[]>([]);
const freeformHeaders = ref<string[]>([]);
const gridRows = ref<SheetRow[]>([]);
const isLoadingSheets = ref(false);
const isLoadingTables = ref(false);
const sheetErrorMessage = ref<string | null>(null);
const tableErrorMessage = ref<string | null>(null);
const sheetRequestSeq = ref(0);
const tableRequestSeq = ref(0);
const freeformMode = ref<'positional' | 'named'>('positional');
const lastEmittedJson = ref<string | null>(null);

const credentialRef = computed(() => state?.fieldValues.value?.credential_ref);
const spreadsheetId = computed(() => state?.fieldValues.value?.spreadsheet_id);
const sheetName = computed(() => state?.fieldValues.value?.sheet_name);
const tableId = computed(() => state?.fieldValues.value?.table_id);

const isFilledString = (value: unknown): value is string =>
  typeof value === 'string' && value.trim() !== '';

const hasCredential = computed(() => {
  const ref = credentialRef.value;
  return !!ref && typeof ref === 'object';
});

const canResolveLookups = computed(() =>
  hasCredential.value &&
  isFilledString(spreadsheetId.value)
);

const selectedSheetName = computed(() => {
  if (isFilledString(sheetName.value)) return sheetName.value.trim();
  return '';
});

const selectedTableId = computed(() => {
  if (isFilledString(tableId.value)) return tableId.value.trim();
  return '';
});

const selectedTableOption = computed(() => {
  const selected = selectedTableId.value;
  if (selected === '') return null;
  return tableOptions.value.find(option => option.id === selected) ?? null;
});

const schemaHeaders = computed(() =>
  selectedTableOption.value?.columns.map(column => column.label).filter(label => label !== '') ?? []
);
const schemaLocked = computed(() => schemaHeaders.value.length > 0);
const usesNamedFreeformHeaders = computed(
  () => !schemaLocked.value && freeformMode.value === 'named'
);

const displayHeaders = computed(() =>
  schemaLocked.value ? schemaHeaders.value : freeformHeaders.value
);

const columnCount = computed(() =>
  schemaLocked.value
    ? displayHeaders.value.length
    : Math.max(displayHeaders.value.length, maxRowWidth(gridRows.value), DEFAULT_COLUMN_COUNT)
);

const columnIndexes = computed(() =>
  Array.from({ length: columnCount.value }, (_value, index) => index)
);

const gridTemplateColumns = computed(
  () => `repeat(${columnCount.value}, minmax(8.5rem, 1fr)) 2.5rem`
);

const selectedTableLabel = computed(() => {
  if (selectedTableOption.value) return selectedTableOption.value.label;
  if (selectedTableId.value !== '') return selectedTableId.value;
  return 'No table selected';
});

const sheetStatusLabel = computed(() => {
  if (schemaLocked.value) {
    return `${schemaHeaders.value.length} fixed ${schemaHeaders.value.length === 1 ? 'column' : 'columns'}`;
  }
  if (isLoadingTables.value) return 'Loading table schema; editing stays available';
  if (tableErrorMessage.value) return 'Table lookup failed; editing stays available';
  if (selectedTableId.value !== '') return 'Table schema unavailable; editing stays available';
  return 'Flexible columns';
});

const sheetSelectId = computed(() => `${props.nodeId}-${props.field.key}-sheet`);
const sheetSelectValue = computed(() => selectedSheetName.value);
const tableSelectId = computed(() => `${props.nodeId}-${props.field.key}-table`);
const tableSelectValue = computed(() => selectedTableId.value);

const sheetSelectOptions = computed(() => {
  const seen = new Set<string>();
  const options: SheetOption[] = [];
  const selected = selectedSheetName.value;

  if (selected !== '') {
    seen.add(selected);
    options.push({ id: selected, label: selected });
  }

  sheetOptions.value.forEach(option => {
    if (option.id === '' || seen.has(option.id)) return;
    seen.add(option.id);
    options.push(option);
  });

  return options;
});

const tableSelectOptions = computed(() => {
  const seen = new Set<string>();
  const options: TableOption[] = [];
  const selected = selectedTableId.value;
  const selectedSheet = selectedSheetName.value;

  if (selected !== '') {
    seen.add(selected);
    options.push(
      selectedTableOption.value ?? {
        id: selected,
        label: selected,
        sheetName: selectedSheet,
        columns: [],
      }
    );
  }

  tableOptions.value.forEach(option => {
    if (selectedSheet !== '' && option.sheetName !== selectedSheet) return;
    if (option.id === '' || seen.has(option.id)) return;
    seen.add(option.id);
    options.push(option);
  });

  return options;
});

const canRefreshLookup = computed(() => canResolveLookups.value);
const isRefreshingLookup = computed(() => isLoadingSheets.value || isLoadingTables.value);
const refreshLabel = computed(() => {
  if (isRefreshingLookup.value) return 'Refreshing Google Sheets metadata';
  return 'Refresh sheets and tables';
});

const rowSummary = computed(() => {
  const rows = gridRows.value.length;
  const columns = columnCount.value;
  return `${rows} ${rows === 1 ? 'row' : 'rows'} x ${columns} ${columns === 1 ? 'column' : 'columns'}`;
});

const cellPlaceholder = computed(() => `Value or {{ expression }}`);

const maxRowWidth = (rows: SheetRow[]) =>
  rows.reduce((max, row) => Math.max(max, row.length), 0);

const toCellString = (value: unknown): string => {
  if (value === null || value === undefined) return '';
  if (typeof value === 'string') return value;
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
};

const isRecord = (value: unknown): value is Record<string, unknown> =>
  !!value && typeof value === 'object' && !Array.isArray(value);

const isListOfRecords = (value: unknown): value is Record<string, unknown>[] =>
  Array.isArray(value) && value.length > 0 && value.every(isRecord);

const isListOfLists = (value: unknown): value is unknown[][] =>
  Array.isArray(value) && value.length > 0 && value.every(Array.isArray);

const columnName = (index: number) => {
  let name = '';
  let n = index + 1;

  while (n > 0) {
    const remainder = (n - 1) % 26;
    name = String.fromCharCode(65 + remainder) + name;
    n = Math.floor((n - 1) / 26);
  }

  return name;
};

const ensureWidth = (row: SheetRow, width: number): SheetRow => {
  const next = row.slice(0, width);
  while (next.length < width) next.push('');
  return next;
};

const normalizeRows = (rows: SheetRow[], width: number): SheetRow[] => {
  const nextRows = rows.length > 0 ? rows : [emptyRow(width)];
  return nextRows.map(row => ensureWidth(row, width));
};

const emptyRow = (width: number): SheetRow =>
  Array.from({ length: Math.max(width, DEFAULT_COLUMN_COUNT) }, () => '');

const hydrateFromModel = () => {
  if (schemaLocked.value) {
    const width = schemaHeaders.value.length;
    freeformMode.value = 'named';
    freeformHeaders.value = schemaHeaders.value;
    gridRows.value = normalizeRows(rowsFromValue(props.modelValue, schemaHeaders.value), width);
    emitIfSchemaSerializationChanged();
    return;
  }

  const { headers, rows, mode } = freeformStateFromValue(props.modelValue);
  freeformMode.value = mode;
  freeformHeaders.value = headers;
  gridRows.value = normalizeRows(rows, Math.max(headers.length, maxRowWidth(rows), DEFAULT_COLUMN_COUNT));
};

const rowsFromValue = (value: unknown, headers: string[]): SheetRow[] => {
  if (isListOfRecords(value)) {
    return value.map(row => headers.map(header => toCellString(row[header])));
  }

  if (isRecord(value)) {
    return [headers.map(header => toCellString(value[header]))];
  }

  if (isListOfLists(value)) {
    return value.map((row, index) =>
      alignPositionalRowToHeaders(row.map(toCellString), headers.length, index)
    );
  }

  if (Array.isArray(value)) {
    return [alignPositionalRowToHeaders(value.map(toCellString), headers.length, 0)];
  }

  return [emptyRow(headers.length)];
};

const freeformStateFromValue = (value: unknown): {
  headers: string[];
  rows: SheetRow[];
  mode: 'positional' | 'named';
} => {
  if (isListOfRecords(value)) {
    const headers = uniqueKeys(value);
    return {
      headers: headers.length > 0 ? headers : defaultHeaders(),
      rows: value.map(row => headers.map(header => toCellString(row[header]))),
      mode: 'named',
    };
  }

  if (isRecord(value)) {
    const headers = Object.keys(value);
    return {
      headers: headers.length > 0 ? headers : defaultHeaders(),
      rows: [headers.map(header => toCellString(value[header]))],
      mode: 'named',
    };
  }

  if (isListOfLists(value)) {
    const rows = value.map(row => row.map(toCellString));
    return {
      headers: blankHeaders(Math.max(maxRowWidth(rows), DEFAULT_COLUMN_COUNT)),
      rows,
      mode: 'positional',
    };
  }

  if (Array.isArray(value)) {
    const row = value.map(toCellString);
    return {
      headers: blankHeaders(Math.max(row.length, DEFAULT_COLUMN_COUNT)),
      rows: [row],
      mode: 'positional',
    };
  }

  return {
    headers: defaultHeaders(),
    rows: [emptyRow(DEFAULT_COLUMN_COUNT)],
    mode: 'positional',
  };
};

const uniqueKeys = (rows: Record<string, unknown>[]) => {
  const seen = new Set<string>();
  const keys: string[] = [];

  rows.forEach(row => {
    Object.keys(row).forEach(key => {
      if (!seen.has(key)) {
        seen.add(key);
        keys.push(key);
      }
    });
  });

  return keys;
};

const alignPositionalRowToHeaders = (row: SheetRow, headerCount: number, rowIndex: number) => {
  const firstCell = row[0]?.trim();
  const rowNumber = String(rowIndex + 1);

  if (row.length === headerCount + 1 && firstCell === rowNumber) {
    return row.slice(1);
  }

  return row;
};

const defaultHeaders = () => blankHeaders(DEFAULT_COLUMN_COUNT);
const blankHeaders = (count: number) => Array.from({ length: count }, () => '');

const onHeaderInput = (columnIndex: number, value: string) => {
  const headers = ensureHeaderWidth(freeformHeaders.value, columnCount.value);
  headers[columnIndex] = value;
  freeformHeaders.value = headers;
  emitValue();
};

const onCellInput = (rowIndex: number, columnIndex: number, value: string) => {
  const rows = gridRows.value.map(row => ensureWidth(row, columnCount.value));
  rows[rowIndex][columnIndex] = value;
  gridRows.value = rows;
  emitValue();
};

const addColumn = () => {
  if (schemaLocked.value) return;
  freeformHeaders.value = [...ensureHeaderWidth(freeformHeaders.value, columnCount.value), ''];
  gridRows.value = gridRows.value.map(row => [...ensureWidth(row, columnCount.value), '']);
};

const addRow = () => {
  gridRows.value = [...gridRows.value, emptyRow(columnCount.value)];
};

const removeRow = (rowIndex: number) => {
  if (gridRows.value.length <= 1) return;
  gridRows.value = gridRows.value.filter((_row, index) => index !== rowIndex);
  emitValue();
};

const onSheetSelectionChange = (value: string) => {
  updateSelectedSheet(value);
  updateSelectedTable('');
  switchToPositionalFreeform();
};

const onTableSelectionChange = (value: string) => {
  if (value.trim() === '') {
    updateSelectedTable('');
    switchToPositionalFreeform();
    return;
  }

  updateSelectedTable(value);
};

const updateSelectedSheet = (value: string) => {
  const normalized = value.trim();

  if (!state) return;
  state.fieldValues.value = {
    ...state.fieldValues.value,
    sheet_name: normalized,
  };
};

const updateSelectedTable = (value: string) => {
  const normalized = value.trim();
  const table = tableOptions.value.find(option => option.id === normalized);

  if (!state) return;
  state.fieldValues.value = {
    ...state.fieldValues.value,
    table_id: normalized,
    sheet_name: table?.sheetName ?? selectedSheetName.value,
  };
};

const switchToPositionalFreeform = () => {
  const width = Math.max(maxRowWidth(gridRows.value), DEFAULT_COLUMN_COUNT);
  freeformMode.value = 'positional';
  freeformHeaders.value = blankHeaders(width);
  gridRows.value = normalizeRows(gridRows.value, width);
  emitValue();
};

const ensureHeaderWidth = (headers: string[], width: number) => {
  const next = headers.slice(0, width);
  while (next.length < width) next.push('');
  return next;
};

const emitValue = () => {
  const serialized = serializeRows();
  lastEmittedJson.value = safeJson(serialized);
  emit('validation', null);
  emit('update:modelValue', serialized);
};

const emitIfSchemaSerializationChanged = () => {
  const serialized = serializeRows();
  if (!valuesEqual(serialized, props.modelValue)) {
    lastEmittedJson.value = safeJson(serialized);
    emit('update:modelValue', serialized);
  }
};

const serializeRows = (): unknown => {
  const rows = dropTrailingEmptyRows(
    gridRows.value.map(row => ensureWidth(row, columnCount.value))
  );

  if (schemaLocked.value) {
    return serializeNamedRows(rows, schemaHeaders.value);
  }

  if (freeformMode.value === 'named') {
    return serializeNamedRows(rows, freeformHeaders.value);
  }

  return serializePositionalRows(rows);
};

const serializeNamedRows = (rows: SheetRow[], headers: string[]) => {
  const normalizedHeaders = headers.map(header => header.trim());
  const serialized = rows.map(row => {
    const record: Record<string, unknown> = {};

    normalizedHeaders.forEach((header, index) => {
      if (header === '') return;
      const value = row[index] ?? '';
      if (value !== '') record[header] = value;
    });

    return record;
  });

  return oneOrMany(serialized);
};

const serializePositionalRows = (rows: SheetRow[]) =>
  oneOrMany(rows.map(trimTrailingEmptyCells));

const oneOrMany = (rows: SerializedRow[]) => {
  if (rows.length === 0) return [];
  if (rows.length === 1) return rows[0];
  return rows;
};

const trimTrailingEmptyCells = (row: SheetRow) => {
  const next = [...row];
  while (next.length > 0 && next[next.length - 1] === '') next.pop();
  return next;
};

const dropTrailingEmptyRows = (rows: SheetRow[]) => {
  const next = rows.map(row => [...row]);
  while (next.length > 1 && next[next.length - 1].every(cell => cell === '')) {
    next.pop();
  }
  return next;
};

const valuesEqual = (left: unknown, right: unknown) =>
  safeJson(left) === safeJson(right);

const safeJson = (value: unknown) => {
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
};

const headerInputId = (columnIndex: number) =>
  `${props.nodeId}-${props.field.key}-header-${columnIndex}`;

const cellInputId = (rowIndex: number, columnIndex: number) =>
  `${props.nodeId}-${props.field.key}-${rowIndex}-${columnIndex}`;

const fetchSheets = () => {
  sheetRequestSeq.value += 1;
  const seq = sheetRequestSeq.value;

  if (!canResolveLookups.value) {
    sheetOptions.value = [];
    isLoadingSheets.value = false;
    sheetErrorMessage.value = null;
    return;
  }

  isLoadingSheets.value = true;
  sheetErrorMessage.value = null;

  try {
    live.pushEvent(
      'resolve_field_options',
      {
        node_id: props.nodeId,
        field_key: props.field.key,
        params: {
          mode: 'sheets',
          credential_ref: credentialRef.value,
          spreadsheet_id: spreadsheetId.value,
        },
        q: '',
      },
      (reply: any) => {
        if (seq !== sheetRequestSeq.value) return;

        isLoadingSheets.value = false;
        if (reply?.error) {
          sheetErrorMessage.value = describeSheetError(reply.error);
          sheetOptions.value = [];
          return;
        }

        sheetOptions.value = normalizeSheetOptions(reply?.options);
      }
    );
  } catch (error) {
    if (seq !== sheetRequestSeq.value) return;
    isLoadingSheets.value = false;
    sheetErrorMessage.value = 'Could not load sheets from this spreadsheet.';
    sheetOptions.value = [];
    console.error('MapEditor: sheet resolve_field_options failed', error);
  }
};

const fetchTables = () => {
  tableRequestSeq.value += 1;
  const seq = tableRequestSeq.value;

  if (!canResolveLookups.value) {
    tableOptions.value = [];
    isLoadingTables.value = false;
    tableErrorMessage.value = null;
    return;
  }

  isLoadingTables.value = true;
  tableErrorMessage.value = null;

  try {
    live.pushEvent(
      'resolve_field_options',
      {
        node_id: props.nodeId,
        field_key: props.field.key,
        params: {
          mode: 'tables',
          credential_ref: credentialRef.value,
          spreadsheet_id: spreadsheetId.value,
        },
        q: '',
      },
      (reply: any) => {
        if (seq !== tableRequestSeq.value) return;

        isLoadingTables.value = false;
        if (reply?.error) {
          tableErrorMessage.value = describeTableError(reply.error);
          tableOptions.value = [];
          return;
        }

        tableOptions.value = normalizeTableOptions(reply?.options);
      }
    );
  } catch (error) {
    if (seq !== tableRequestSeq.value) return;
    isLoadingTables.value = false;
    tableErrorMessage.value = 'Could not load tables from this spreadsheet.';
    tableOptions.value = [];
    console.error('MapEditor: table resolve_field_options failed', error);
  }
};

const refreshLookups = () => {
  if (!canResolveLookups.value) return;
  fetchSheets();
  fetchTables();
};

const normalizeSheetOptions = (options: unknown): SheetOption[] => {
  if (!Array.isArray(options)) return [];

  const seen = new Set<string>();
  const normalized: SheetOption[] = [];

  options.forEach((opt: any) => {
    const id = firstString(opt?.id, opt?.value, opt?.label);
    if (id === '' || seen.has(id)) return;

    seen.add(id);
    normalized.push({
      id,
      label: firstString(opt?.label, opt?.id, opt?.value) || id,
    });
  });

  return normalized;
};

const normalizeTableOptions = (options: unknown): TableOption[] => {
  if (!Array.isArray(options)) return [];

  const seen = new Set<string>();
  const normalized: TableOption[] = [];

  options.forEach((opt: any) => {
    const id = firstString(opt?.id, opt?.value, opt?.label);
    if (id === '' || seen.has(id)) return;

    seen.add(id);
    normalized.push({
      id,
      label: firstString(opt?.label, opt?.id, opt?.value) || id,
      sheetName: firstString(opt?.sheet_name, opt?.sheetName),
      sheetId: numberValue(opt?.sheet_id ?? opt?.sheetId),
      columns: normalizeTableColumns(opt?.columns),
    });
  });

  return normalized;
};

const normalizeTableColumns = (columns: unknown): TableColumnOption[] => {
  if (!Array.isArray(columns)) return [];

  return columns
    .map((column: any, index) => {
      const label = firstString(column?.label, column?.name, column?.id) || columnName(index);
      return {
        id: firstString(column?.id, column?.label, column?.name) || label,
        label,
      };
    })
    .filter(column => column.label !== '');
};

const firstString = (...values: unknown[]) => {
  for (const value of values) {
    if (typeof value === 'string' && value.trim() !== '') return value.trim();
  }

  return '';
};

const numberValue = (value: unknown) => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return undefined;
};

const tableOptionLabel = (option: TableOption) => {
  if (selectedSheetName.value !== '' || option.sheetName === '') return option.label;
  return `${option.label} (${option.sheetName})`;
};

const describeSheetError = (err: unknown): string => {
  if (typeof err === 'string') {
    switch (err) {
      case 'no_google_credential':
        return "Connect a Google account to load this spreadsheet's sheets.";
      case 'unauthorized':
      case 'forbidden':
        return 'Your Google account does not have access to this spreadsheet.';
      case 'spreadsheet_not_found':
        return "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.";
      case 'invalid_range_or_sheet':
        return "Couldn't read that sheet. Make sure the Sheet Name matches the tab in Google Sheets exactly.";
      case 'rate_limited':
        return 'Google rate-limited the lookup. Try again in a moment.';
      case 'fetch_failed':
        return 'Could not load sheets from this spreadsheet.';
      default:
        return err.trim() !== '' ? err : 'Could not load sheets from this spreadsheet.';
    }
  }
  return 'Could not load sheets from this spreadsheet.';
};

const describeTableError = (err: unknown): string => {
  if (typeof err === 'string') {
    switch (err) {
      case 'no_google_credential':
        return "Connect a Google account to load this spreadsheet's tables.";
      case 'unauthorized':
      case 'forbidden':
        return 'Your Google account does not have access to this spreadsheet.';
      case 'spreadsheet_not_found':
        return "Couldn't find that spreadsheet. Double-check the Spreadsheet ID.";
      case 'rate_limited':
        return 'Google rate-limited the lookup. Try again in a moment.';
      case 'fetch_failed':
        return 'Could not load tables from this spreadsheet.';
      default:
        return err.trim() !== '' ? err : 'Could not load tables from this spreadsheet.';
    }
  }
  return 'Could not load tables from this spreadsheet.';
};

watch(
  () => props.modelValue,
  () => {
    if (safeJson(props.modelValue) === lastEmittedJson.value) return;
    hydrateFromModel();
  },
  { immediate: true, deep: true }
);

watch(schemaHeaders, () => hydrateFromModel(), { deep: true });

watchDebounced(
  [credentialRef, spreadsheetId],
  () => refreshLookups(),
  { debounce: 400, immediate: true, deep: true }
);
</script>
