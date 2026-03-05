import { onBeforeUnmount, onMounted } from 'vue';

export function useDocumentEvent<K extends keyof DocumentEventMap>(
  type: K,
  listener: (event: DocumentEventMap[K]) => void,
  options?: AddEventListenerOptions
) {
  onMounted(() => {
    document.addEventListener(type, listener as EventListener, options);
  });

  onBeforeUnmount(() => {
    document.removeEventListener(type, listener as EventListener, options);
  });
}
