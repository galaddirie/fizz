import { ref, computed, type ComputedRef, type Ref } from 'vue';
import type { Node } from '@vue-flow/core';
import type { EditorState, StepNodeData } from '@/types/workflow';

interface UseWebhookTestOptions {
    node: () => Node<StepNodeData> | null;
    editorState: () => EditorState | undefined;
    canEdit: ComputedRef<boolean>;
    fieldValues: Ref<Record<string, unknown>>;
    emit: (...args: any[]) => void;
}

export function useWebhookTest({
    node,
    editorState,
    canEdit,
    fieldValues,
    emit,
}: UseWebhookTestOptions) {
    const webhookMode = ref<'test' | 'production'>('test');

    const isWebhookTrigger = computed(() => {
        const typeId = node()?.data?.type_id;
        return typeId === 'webhook_trigger' || typeId === 'webhook';
    });

    const webhookPath = computed(() => {
        const n = node();
        if (!n) return '';
        const rawPath = fieldValues.value?.path || n.data?.config?.path;
        const path = typeof rawPath === 'string' ? rawPath.trim() : '';
        return path.length > 0 ? path : n.id;
    });

    const webhookMethod = computed(() => {
        const rawMethod = node()?.data?.config?.http_method;
        if (typeof rawMethod === 'string' && rawMethod.trim().length > 0) {
            return rawMethod.trim().toUpperCase();
        }
        return 'POST';
    });

    const webhookTestState = computed(() => editorState()?.webhook_test || null);

    const isWebhookListening = computed(() => {
        const n = node();
        if (!n || !webhookTestState.value) return false;
        if (webhookTestState.value.step_id) {
            return webhookTestState.value.step_id === n.id;
        }
        return webhookTestState.value.path === webhookPath.value;
    });

    const isWebhookListeningElsewhere = computed(() => {
        const n = node();
        if (!n || !webhookTestState.value) return false;
        return webhookTestState.value.step_id
            ? webhookTestState.value.step_id !== n.id
            : webhookTestState.value.path !== webhookPath.value;
    });

    const webhookUrl = computed(() => {
        const n = node();
        if (!n) return '';
        const path = webhookPath.value;
        const baseUrl = window.location.origin;

        if (webhookMode.value === 'test') {
            return `${baseUrl}/api/hook-test/${path}`;
        } else {
            return `${baseUrl}/api/hooks/${path}`;
        }
    });

    const copyWebhookUrl = () => {
        navigator.clipboard.writeText(webhookUrl.value);
    };

    const toggleWebhookListening = () => {
        if (!canEdit.value) return;
        const n = node();
        if (!n || isWebhookListeningElsewhere.value) return;
        emit('toggle_webhook_test', {
            action: isWebhookListening.value ? 'stop' : 'start',
            step_id: n.id,
            path: webhookPath.value,
            method: webhookMethod.value,
        });
    };

    return {
        webhookMode,
        isWebhookTrigger,
        webhookPath,
        webhookMethod,
        webhookTestState,
        isWebhookListening,
        isWebhookListeningElsewhere,
        webhookUrl,
        copyWebhookUrl,
        toggleWebhookListening,
    };
}
