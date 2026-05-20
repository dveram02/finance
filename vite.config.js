import { defineConfig } from 'vite';
import laravel from 'laravel-vite-plugin';
import vue from '@vitejs/plugin-vue';

export default defineConfig({
    plugins: [
        laravel({
            input: 'resources/js/app.js',
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
