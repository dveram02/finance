import defaultTheme from 'tailwindcss/defaultTheme';
import forms from '@tailwindcss/forms';

/** @type {import('tailwindcss').Config} */
export default {
    // Dark mode is toggled via <html class="dark">; managed by useDarkMode.js
    darkMode: 'class',

    content: [
        './vendor/laravel/framework/src/Illuminate/Pagination/resources/views/*.blade.php',
        './storage/framework/views/*.php',
        './resources/views/**/*.blade.php',
        './resources/js/**/*.vue',
    ],

    theme: {
        extend: {
            fontFamily: {
                sans: ['Figtree', ...defaultTheme.fontFamily.sans],
            },

            colors: {
                // ── Surface tokens (background colours) ───────────────────────────
                // Values are bare RGB channels so Tailwind opacity modifiers
                // (/50, /80 …) work on every token — e.g. bg-surface/80.
                //
                //   Tailwind class   Replaces          Light        Dark
                //   ─────────────────────────────────────────────────────────────
                //   bg-surface       bg-white          white        gray-900
                //   bg-surface-2     bg-gray-50        gray-50      gray-800
                //   bg-surface-3     bg-gray-100       gray-100     gray-700
                //   bg-surface-4     bg-gray-200       gray-200     gray-600
                surface: {
                    DEFAULT: 'rgb(var(--color-surface)   / <alpha-value>)',
                    2:       'rgb(var(--color-surface-2) / <alpha-value>)',
                    3:       'rgb(var(--color-surface-3) / <alpha-value>)',
                    4:       'rgb(var(--color-surface-4) / <alpha-value>)',
                },

                // ── Text tokens ────────────────────────────────────────────────────
                // Namespace "tx" avoids clashing with Tailwind's built-in color names.
                //
                //   Tailwind class     Replaces          Light        Dark
                //   ─────────────────────────────────────────────────────────────
                //   text-tx-primary    text-gray-900     gray-900     white
                //   text-tx-body       text-gray-700     gray-700     gray-200
                //   text-tx-muted      text-gray-600     gray-600     gray-300
                //   text-tx-subtle     text-gray-500     gray-500     gray-400
                tx: {
                    primary: 'rgb(var(--color-tx-primary) / <alpha-value>)',
                    body:    'rgb(var(--color-tx-body)    / <alpha-value>)',
                    muted:   'rgb(var(--color-tx-muted)   / <alpha-value>)',
                    subtle:  'rgb(var(--color-tx-subtle)  / <alpha-value>)',
                },

                // ── Border / divider tokens ────────────────────────────────────────
                // Namespace "line" avoids clashing with Tailwind's "border" keyword.
                //
                //   Tailwind class       Replaces            Light        Dark
                //   ─────────────────────────────────────────────────────────────
                //   border-line          border-gray-200     gray-200     gray-700
                //   border-line-input    border-gray-300     gray-300     gray-600
                //   divide-line          divide-gray-200     gray-200     gray-700
                line: {
                    DEFAULT: 'rgb(var(--color-line)       / <alpha-value>)',
                    input:   'rgb(var(--color-line-input) / <alpha-value>)',
                },
            },
        },
    },

    plugins: [forms],
};
