import { h, type Component } from 'vue';
import { createLiveVue, findComponent, type LiveHook, type ComponentMap } from 'live_vue';

// needed to make $live available in the Vue component
declare module 'vue' {
  interface ComponentCustomProperties {
    $live: LiveHook;
  }
}

import { createPinia } from 'pinia';

export default createLiveVue({
  // name will be passed as-is in v-component of the .vue HEEX component
  resolve: name => {
    // we're importing from ../../lib to allow collocating Vue files with LiveView files
    // eager: true disables lazy loading - all these components will be part of the app.js bundle
    // more: https://vite.dev/guide/features.html#glob-import
    const components = {
      ...import.meta.glob('./**/*.vue', { eager: true }),
      ...import.meta.glob('../../lib/**/*.vue', { eager: true }),
    } as ComponentMap;

    // finds component by name or path suffix and gives a nice error message.
    // `path/to/component/index.vue` can be found as `path/to/component` or simply `component`
    // `path/to/Component.vue` can be found as `path/to/Component` or simply `Component`
    return findComponent(components as ComponentMap, name);
  },
  // Standard LiveVue setup - props are already reactive from the VueHook
  setup: ({ createApp, component, props, slots, plugin, el }) => {
    const app = createApp({ render: () => h(component as Component, props, slots) });
    const pinia = createPinia();
    app.use(pinia);
    app.use(plugin);
    app.mount(el);
    return app;
  },
});
