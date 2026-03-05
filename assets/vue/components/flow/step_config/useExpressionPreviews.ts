import type { Node } from '@vue-flow/core';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';

export interface ErrorPayload {
    type: 'parse_error' | 'render_error';
    message?: string;
    errors?: string[];
    line?: number;
    column?: number;
    text: string;
}

interface UseExpressionPreviewsOptions {
    node: () => Node<StepNodeData> | null;
    expressionPreviews: () => Record<string, unknown> | undefined;
}

export function useExpressionPreviews({ node, expressionPreviews }: UseExpressionPreviewsOptions) {
    const previewKeyFor = (fieldKey: string) => {
        const n = node();
        return n ? `${n.id}:${fieldKey}` : '';
    };

    const hasPreviewFor = (fieldKey: string) => {
        const key = previewKeyFor(fieldKey);
        if (!key) return false;
        return Object.prototype.hasOwnProperty.call(expressionPreviews() || {}, key);
    };

    const previewValueFor = (fieldKey: string) => {
        const key = previewKeyFor(fieldKey);
        if (!key) return undefined;
        return expressionPreviews()?.[key];
    };

    const previewIsError = (value: unknown): value is ErrorPayload => {
        if (!value || typeof value !== 'object') return false;
        const payload = value as Record<string, unknown>;
        return payload.type === 'parse_error' || payload.type === 'render_error';
    };

    const previewToText = (value: unknown) => {
        if (value === null) return 'null';
        if (value === undefined) return 'undefined';
        if (typeof value === 'string') return value;
        if (typeof value === 'number' || typeof value === 'boolean') return String(value);

        try {
            return JSON.stringify(value, null, 2);
        } catch {
            return String(value);
        }
    };

    return {
        previewKeyFor,
        hasPreviewFor,
        previewValueFor,
        previewIsError,
        previewToText,
    };
}
