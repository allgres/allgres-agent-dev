import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { viteSingleFile } from 'vite-plugin-singlefile';

// The extension serves exactly one HTML document per route from memory
// (include_str! in src/lib.rs), so the build must inline every script and
// stylesheet. scripts/emit.mjs then stamps the CSP nonce placeholder onto
// each inline tag and writes web/canvas.html.
export default defineConfig({
  plugins: [react(), viteSingleFile({ removeViteModuleLoader: true })],
  build: {
    outDir: 'dist',
    emptyOutDir: true,
    modulePreload: false,
    reportCompressedSize: false,
  },
  server: {
    // Development only: the extension's CSRF check requires Origin to match
    // Host, so the proxy presents the dashboard's own origin. Nothing here
    // ships in the built file.
    proxy: {
      '/api': {
        target: process.env.ALLGRES_UI_URL || 'http://127.0.0.1:8088',
        changeOrigin: true,
        configure: (proxy, options) => {
          proxy.on('proxyReq', (req) => req.setHeader('origin', String(options.target)));
        },
      },
    },
  },
});
