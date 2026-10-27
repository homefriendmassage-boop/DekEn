import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// GitHub Pages serves the site at https://<user>.github.io/<repo>/, so assets
// need that sub-path as their base. The CI workflow sets VITE_BASE=/<repo>/;
// locally it falls back to "/".
export default defineConfig({
  base: process.env.VITE_BASE || '/',
  plugins: [react()],
})
