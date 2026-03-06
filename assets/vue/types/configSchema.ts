export type UIComponent = "select" | "search" | "string" | "number";

export interface UIResolverConfig {
  resolver: string;
  params?: Record<string, unknown>;
}

export interface UIResponseMapping {
  value?: string;
  label?: string;
  description?: string;
  meta?: Array<{ key: string; value: string; format?: string }>;
}

export interface UIResponseConfig {
  mapping?: UIResponseMapping;
}

export interface FieldUIConfig extends UIResolverConfig {
  component?: UIComponent;
  options?: Array<{ label: string; value: unknown }>;
  responseConfig?: UIResponseConfig;
}

export interface ConfigSchemaField {
  title?: string;
  type?: string;
  format?: string;
  default?: unknown;
  description?: string;
  placeholder?: string;
  enum?: unknown[];
  ui?: FieldUIConfig;
}

export interface ConfigSchema {
  type?: string;
  required?: string[];
  properties?: Record<string, ConfigSchemaField>;
}

export type ExtendedFieldType =
  | "text"
  | "number"
  | "boolean"
  | "textarea"
  | "json"
  | "search"
  | "select";

export interface ConfigField {
  key: string;
  label: string;
  type: ExtendedFieldType;
  description?: string;
  placeholder?: string;
  expressionCapable: boolean;
  disabled?: boolean;
  readOnly?: boolean;
  ui?: FieldUIConfig;
  enum?: unknown[];
  default?: unknown;
}
