/**
 * Types for the declarative step configuration schema system.
 *
 * Backend Elixir schemas define JSON Schema properties with an optional `ui`
 * extension that controls how each field is rendered in the step config modal.
 */

// ---------------------------------------------------------------------------
// UI extension types
// ---------------------------------------------------------------------------

/** Supported UI component types for field rendering. */
export type UIComponent = 'select' | 'search' | 'string' | 'number';

/** Resolver-based configuration for dynamic option loading. */
export interface UIResolverConfig {
    /** Name of the backend resolver (e.g. "credentials"). */
    resolver: string;
    /** Params forwarded to the resolver (e.g. provider_filter, auth_types). */
    params?: Record<string, unknown>;
}

/** Response mapping for search result shaping. */
export interface UIResponseMapping {
    value?: string;
    label?: string;
    description?: string;
    meta?: Array<{ key: string; value: string; format?: string }>;
}

/** Response configuration for search fields. */
export interface UIResponseConfig {
    mapping?: UIResponseMapping;
}

/** The `ui` extension on a config schema field property. */
export interface FieldUIConfig extends UIResolverConfig {
    /** Which component to render. Inferred from JSON Schema if omitted. */
    component?: UIComponent;
    /** Static options for select fields (alternative to resolver). */
    options?: Array<{ label: string; value: unknown }>;
    /** Response mapping config for search result shaping. */
    responseConfig?: UIResponseConfig;
}

// ---------------------------------------------------------------------------
// Config schema types
// ---------------------------------------------------------------------------

/** A single property within a config schema. */
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

/** Top-level config schema (JSON Schema subset). */
export interface ConfigSchema {
    type?: string;
    required?: string[];
    properties?: Record<string, ConfigSchemaField>;
}

// ---------------------------------------------------------------------------
// Resolved field types (after inference in StepConfigModal)
// ---------------------------------------------------------------------------

/** Field types after UI component inference. */
export type ExtendedFieldType = 'text' | 'number' | 'boolean' | 'textarea' | 'json' | 'search' | 'select';

/** A config field with all metadata needed for rendering. */
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
