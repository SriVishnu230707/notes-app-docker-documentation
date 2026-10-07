import { defineConfig } from 'vite';

export default defineConfig({
  // Keep CSS processing local to this project; no ancestor config discovery.
  css: { postcss: { plugins: [] } },
  server: {
    port: 5173,
    strictPort: true,
    watch: { usePolling: true },
    // Preserve the browser-facing host/port for the API's same-origin checks.
    proxy: { '/api': { target: process.env.VITE_API_PROXY_TARGET || 'http://localhost:8000', changeOrigin: false } },
  },
});
