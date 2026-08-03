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
      animation: {
        'pulse-soft': 'pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite',
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
