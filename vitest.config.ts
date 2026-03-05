import { resolve } from 'node:path';

import { defineConfig } from 'vitest/config';

export default defineConfig({
  resolve: {
    alias: {
      '@': resolve(__dirname, 'assets/vue'),
    },
  },
  test: {
    environment: 'jsdom',
    include: ['assets/vue/**/*.test.ts'],
  },
});
