import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  // ../roms/zx48.rom is outside the page's root (instant load bundles it)
  server: { port: 5173, fs: { allow: ['..'] } },
})
