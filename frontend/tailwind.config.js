/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{js,ts,jsx,tsx}'],
  theme: {
    extend: {
      colors: {
        sazonal: {
          verde:     { 50: '#f0fdf4', 100: '#dcfce7', 400: '#4ade80', 600: '#16a34a', 700: '#15803d' },
          amarelo:   { 50: '#fefce8', 100: '#fef9c3', 400: '#facc15', 600: '#ca8a04' },
          vermelho:  { 50: '#fef2f2', 100: '#fee2e2', 400: '#f87171', 600: '#dc2626' },
        },
      },
      animation: {
        'pulse-soft': 'pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite',
      },
    },
  },
  plugins: [],
}
