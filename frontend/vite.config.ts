/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'
import path from 'path'

export default defineConfig({
  resolve: {
    alias: {
      '@': path.resolve(__dirname, './src'),
    },
  },
  server: {
    proxy: {
      '/api': {
        target: 'http://localhost:8000',
        changeOrigin: true,
      },
    },
  },
  plugins: [
    react(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: [
        'favicon.svg',
        'icon-192x192.png',
        'icon-512x512.png',
        'icon-192x192-maskable.png',
        'icon-512x512-maskable.png',
      ],
      manifest: {
        name: 'Sazo Brasil — Sazonalidade de Hortifrúti',
        short_name: 'Sazo Brasil',
        description:
          'Descubra a melhor época para comprar hortifrúti. ' +
          'Análise de sazonalidade baseada em dados CONAB.',
        theme_color: '#16a34a',
        background_color: '#f0fdf4',
        display: 'standalone',
        display_override: ['window-controls-overlay', 'standalone'],
        orientation: 'portrait',
        start_url: '/',
        scope: '/',
        lang: 'pt-BR',
        categories: ['shopping', 'food', 'utilities'],
        shortcuts: [
          {
            name: 'Pesquisar Produto',
            short_name: 'Buscar',
            description: 'Pesquisar sazonalidade de um produto',
            url: '/?search',
            icons: [{ src: '/favicon.svg', sizes: 'any', type: 'image/svg+xml' }],
          },
        ],
        icons: [
          {
            src: '/favicon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'any',
          },
          {
            src: '/favicon.svg',
            sizes: 'any',
            type: 'image/svg+xml',
            purpose: 'maskable',
          },
          {
            src: '/icon-192x192.png',
            sizes: '192x192',
            type: 'image/png',
            purpose: 'any',
          },
          {
            src: '/icon-512x512.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'any',
          },
          {
            src: '/icon-192x192-maskable.png',
            sizes: '192x192',
            type: 'image/png',
            purpose: 'maskable',
          },
          {
            src: '/icon-512x512-maskable.png',
            sizes: '512x512',
            type: 'image/png',
            purpose: 'maskable',
          },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,ico,woff2,webp}'],
        navigateFallback: '/',
        navigateFallbackDenylist: [/\/api\//],
        runtimeCaching: [
          // API de sazonalidade — Stale-While-Revalidate
          {
            urlPattern: /^https?:\/\/.*\/api\/v1\/sazonalidade.*/i,
            handler: 'StaleWhileRevalidate',
            options: {
              cacheName: 'api-sazonalidade',
              expiration: {
                maxEntries: 100,
                maxAgeSeconds: 60 * 60 * 24 * 7,
              },
              cacheableResponse: { statuses: [0, 200] },
              backgroundSync: {
                name: 'sync-sazonalidade',
                options: {
                  maxRetentionTime: 24 * 60,
                },
              },
            },
          },
          // API de municípios — Cache First (24h)
          {
            urlPattern: /^https?:\/\/.*\/api\/v1\/municipios.*/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'api-municipios',
              expiration: {
                maxEntries: 50,
                maxAgeSeconds: 60 * 60 * 24,
              },
              cacheableResponse: { statuses: [0, 200] },
            },
          },
          // Imagens — Cache First (30 dias)
          {
            urlPattern: /\.(?:png|jpg|jpeg|svg|gif|webp)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'image-cache',
              expiration: {
                maxEntries: 50,
                maxAgeSeconds: 60 * 60 * 24 * 30,
              },
            },
          },
          // Fontes — Cache First (60 dias)
          {
            urlPattern: /\.(?:woff|woff2|ttf|eot)$/i,
            handler: 'CacheFirst',
            options: {
              cacheName: 'font-cache',
              expiration: {
                maxEntries: 20,
                maxAgeSeconds: 60 * 60 * 24 * 60,
              },
            },
          },
        ],
      },
    }),
  ],
  test: {
    globals: true,
    environment: 'jsdom',
    setupFiles: './src/test/setup.ts',
    css: true,
  },
  build: {
    target: 'es2020',
    sourcemap: false,
    rollupOptions: {
      output: {
        manualChunks: {
          // React — muda raramente, cache longo
          'vendor-react': ['react', 'react-dom', 'react/jsx-runtime'],
          // Lucide icons — grande, muda raramente
          'vendor-icons': ['lucide-react'],
          // State management + data fetching
          'vendor-store': ['zustand', '@tanstack/react-query'],
          // Axios
          'vendor-http': ['axios'],
        },
      },
    },
  },
})
