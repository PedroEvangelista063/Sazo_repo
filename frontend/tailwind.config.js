/** @type {import('tailwindcss').Config} */
export default {
  darkMode: 'class',
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        sazonal: {
          verde: {
            50: '#f0fdf4',
            100: '#dcfce7',
            400: '#4ade80',
            600: '#16a34a',
            700: '#15803d',
            dark: '#14532d',
          },
          amarelo: {
            50: '#fefce8',
            100: '#fef9c3',
            400: '#facc15',
            600: '#ca8a04',
            dark: '#a16207',
          },
          vermelho: {
            50: '#fef2f2',
            100: '#fee2e2',
            400: '#f87171',
            600: '#dc2626',
            dark: '#991b1b',
          },
        },
      },
      keyframes: {
        // Slide horizontal contínuo do background (mapa do Brasil)
        'slide-horizontal': {
          '0%': { backgroundPositionX: '0%' },
          '100%': { backgroundPositionX: '100%' },
        },
        // Piscar suave — opacidade 0.3 ↔ 0.8 num ciclo longo (5s)
        'blink-slow': {
          '0%, 100%': { opacity: '0.3' },
          '50%': { opacity: '0.8' },
        },
        // Pulsar suave — scale 1 ↔ 1.05 num ciclo longo (6s)
        'pulse-soft': {
          '0%, 100%': { transform: 'scale(1)' },
          '50%': { transform: 'scale(1.05)' },
        },
        // Combinada (blink + pulse) — evita o conflito de duas `animate-*`
        // no mesmo elemento (o shorthand `animation` não empilha)
        'flag-breathe': {
          '0%, 100%': { opacity: '0.3', transform: 'scale(1)' },
          '50%': { opacity: '0.8', transform: 'scale(1.05)' },
        },
        // Crossfade de slides — cada bandeira ocupa um slot de 6s num ciclo de
        // 162s (27 bandeiras). Fades apenas nas bordas (4%→94% opaco): a bandeira
        // N desvanece no fim do slot enquanto a N+1 entra no início — sempre há
        // uma visível (gap máximo de um frame no limite do slot).
        'flag-cycle': {
          '0%': { opacity: '0' },
          '4%': { opacity: '1' },
          '94%': { opacity: '1' },
          '100%': { opacity: '0' },
        },
      },
      animation: {
        'slide-horizontal': 'slide-horizontal 90s linear infinite',
        'blink-slow': 'blink-slow 5s ease-in-out infinite',
        'pulse-soft': 'pulse-soft 6s ease-in-out infinite',
        'flag-breathe': 'flag-breathe 6s ease-in-out infinite',
        'flag-cycle': 'flag-cycle 162s linear infinite',
      },
      boxShadow: {
        // Claymorphism — sombra "argila": drop tintado + inset inferior escuro + inset superior claro
        'clay-card':
          '0 18px 36px -12px rgba(21, 83, 45, 0.28), inset 0 -6px 12px rgba(21, 83, 45, 0.10), inset 0 6px 12px rgba(255, 255, 255, 0.55)',
        'clay-card-hover':
          '0 28px 52px -14px rgba(21, 83, 45, 0.35), inset 0 -6px 12px rgba(21, 83, 45, 0.10), inset 0 6px 12px rgba(255, 255, 255, 0.60)',
        'clay-btn':
          '0 12px 24px -8px rgba(21, 83, 45, 0.35), inset 0 -4px 8px rgba(21, 83, 45, 0.28), inset 0 4px 8px rgba(255, 255, 255, 0.45)',
        'clay-btn-hover':
          '0 16px 32px -10px rgba(21, 83, 45, 0.40), inset 0 -5px 10px rgba(21, 83, 45, 0.30), inset 0 5px 10px rgba(255, 255, 255, 0.50)',
        'clay-press':
          '0 6px 12px -6px rgba(21, 83, 45, 0.30), inset 0 -2px 4px rgba(21, 83, 45, 0.35), inset 0 2px 4px rgba(255, 255, 255, 0.35)',
        'clay-dark':
          '0 25px 50px -12px rgba(0, 0, 0, 0.55), inset 0 -8px 16px rgba(0, 0, 0, 0.45), inset 0 8px 16px rgba(255, 255, 255, 0.06)',
        'clay-dark-hover':
          '0 32px 64px -14px rgba(0, 0, 0, 0.60), inset 0 -8px 16px rgba(0, 0, 0, 0.50), inset 0 8px 16px rgba(255, 255, 255, 0.08)',
      },
      borderRadius: {
        clay: '1.75rem', // 28px — cards
        'clay-sm': '1.25rem', // 20px — tooltips/elementos pequenos
        'clay-lg': '2rem', // 32px — destaque
      },
    },
  },
  plugins: [require('tailwindcss-animate')],
}
