import react from '@vitejs/plugin-react';
import path from 'path';
import {defineConfig, loadEnv} from 'vite';

export default defineConfig(({mode}) => {
  const env = loadEnv(mode, '.', '');
  return {
    base: './',
    build: {
      modulePreload: { polyfill: false },
      rollupOptions: {
        output: {
          manualChunks: {
            'vendor-fluent': ['@fluentui/react-components'],
            'vendor-monaco': ['@monaco-editor/react', 'monaco-editor'],
            'vendor-xterm': ['@xterm/xterm', '@xterm/addon-fit'],
            'vendor-react': ['react', 'react-dom'],
          },
        },
      },
    },
    plugins: [
      react(),
      // Strip crossorigin= from every tag in the built HTML.
      // Required: Android WebView rejects file:// resources fetched with CORS mode.
      {
        name: 'strip-crossorigin',
        transformIndexHtml(html: string) {
          return html.replace(/ crossorigin(="[^"]*")?/g, '');
        },
      },
    ],
    define: {},
    resolve: {
      alias: {
        '@': path.resolve(__dirname, '.'),
      },
      dedupe: ['react', 'react-dom', 'motion'],
    },
    server: {
      hmr: process.env.DISABLE_HMR !== 'true',
      watch: process.env.DISABLE_HMR === 'true' ? null : {},
    },
  };
});
