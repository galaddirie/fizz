export interface StepConfigSavePayload {
  id: string;
  name: string;
  config: Record<string, unknown>;
  notes?: string;
}

export interface StepConfigPreviewExpressionPayload {
  step_id: string;
  field_key: string;
  expression: string;
}

export interface StepConfigPinOutputPayload {
  step_id: string;
  output_data: unknown;
  item_index?: number | null;
}

export interface StepConfigUnpinOutputPayload {
  step_id: string;
}

export type StepConfigEmit = {
  (event: "close"): void;
  (event: "save", payload: StepConfigSavePayload): void;
  (
    event: "preview_expression",
    payload: StepConfigPreviewExpressionPayload
  ): void;
  (event: "pin_output", payload: StepConfigPinOutputPayload): void;
  (event: "unpin_output", payload: StepConfigUnpinOutputPayload): void;
  (event: "run_node", payload: string): void;
};
