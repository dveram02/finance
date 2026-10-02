import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
    plugins: [
        laravel({
            // BOTH entries must be declared, and the CSS one is NOT redundant.
            //
            // resources/js/app.js imports '../css/app.css', so the JS entry
            // already emits its own stylesheet — that is what the Inertia pages
            // in app.blade.php use, and why they need only the JS entry.
            //
            // resources/css/app.css is declared for resources/views/errors/
            // _layout.blade.php, which six Blade error views extend. Those pages
            // are deliberately NOT Inertia and must not boot the Vue app, so they
            // ask for the stylesheet alone. Without this entry Vite::asset()
            // throws for them on a clean build — and because a ViteException
            // renders the 500 page, which extends that same layout, the failure
            // recurses.
            //
            // A single JS-only input is what the sibling inventory-app uses; it
            // is not sufficient here precisely because of those Blade error
            // pages. Do not "simplify" this back to one entry.
            input: [
                'resources/css/app.css',
                'resources/js/app.js',
            ],
            refresh: true,
        }),
        vue({
            template: {
                transformAssetUrls: {
                    base: null,
                    includeAbsolute: false,
                },
            },
        }),
    ],
});

// PRODUCTION WORKING

// import { defineConfig } from 'vite';
// import laravel from 'laravel-vite-plugin';
// import vue from '@vitejs/plugin-vue';

// export default defineConfig(({ command, mode }) => {
//   const isProduction = command === 'build';

//   return {
//     plugins: [
//       laravel({
//         input: [
//           'resources/css/app.css',
//           'resources/js/app.js',
//         ],
//         refresh: true,
//         // optionally you can specify buildDirectory:
//         // buildDirectory: 'build'
//       }),
//       vue({
//         template: {
//           transformAssetUrls: {
//             base: null,
//             includeAbsolute: false,
//           },
//         },
//       }),
//     ],

//     server: !isProduction
//       ? {
//           host: '0.0.0.0',
//           port: 5173,
//           hmr: {
//             host: 'localhost',
//           },
//         }
//       : undefined,

//     build: {
//     outDir: 'public/build',
//     assetsDir: 'assets',
//     manifest: 'manifest.json',   // 👈 force it to public/build/manifest.json
//     rollupOptions: {
//         input: {
//             app: 'resources/js/app.js',
//             'app-style': 'resources/css/app.css', // 👈 optional, but helps Vite register CSS
//         },
//     },
//         target: 'es2015',
//         chunkSizeWarningLimit: 2000,
//     },
//     base: isProduction ? '/build/' : '/',
//   };
// });
