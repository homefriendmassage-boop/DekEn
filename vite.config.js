import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'

// GitHub Pages serves the site at https://<user>.github.io/<repo>/, so assets
// need that sub-path as their base. The CI workflow sets VITE_BASE=/<repo>/;
// locally it falls back to "/".
// Two pages: the customer/provider app (index.html) and the separate back office (admin.html).
export default defineConfig({
  base: process.env.VITE_BASE || '/',
  // shown in the admin header so you can see which version of the site your phone really loaded
  define: { __BUILD_ID__: JSON.stringify(`${(process.env.GITHUB_SHA ?? 'local').slice(0, 7)} · ${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC`) },
  plugins: [react()],
  build: {
    rollupOptions: {
      input: {
        main: fileURLToPath(new URL('./index.html', import.meta.url)),
        admin: fileURLToPath(new URL('./admin.html', import.meta.url)),
      },
    },
  },
})
