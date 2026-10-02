<!DOCTYPE html>
<html lang="{{ str_replace('_', '-', app()->getLocale()) }}">
    <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="csrf-token" content="{{ csrf_token() }}">


        <title inertia>{{ config('app.name', 'Laravel') }}</title>

        <!-- Fonts -->
        <link rel="preconnect" href="https://fonts.bunny.net">
        <link href="https://fonts.bunny.net/css?family=figtree:400,500,600&display=swap" rel="stylesheet" />

        <!-- Prevent flash of light mode on first load when user prefers dark.
             Runs synchronously before any CSS so the 'dark' class is on <html>
             before the browser paints a single pixel. -->
        <script>
            (function () {
                try {
                    var t = localStorage.getItem('theme');
                    if (t === 'dark' || (t === null && window.matchMedia('(prefers-color-scheme: dark)').matches)) {
                        document.documentElement.classList.add('dark');
                    }
                } catch (e) {}
            }());
        </script>

        <!-- Scripts -->
        @routes
        {{-- The JS entry alone. resources/js/app.js does `import '../css/app.css'`,
             so its manifest entry carries the stylesheet in its own `css[]` array
             and @vite emits the <link> for it — asking for resources/css/app.css
             here as well downloaded the same Tailwind build twice.

             The per-page `resources/js/Pages/{$page['component']}.vue` entry that
             used to be here is gone for the same reason the CSS entry is: it was
             never a declared Vite input, so it resolved in dev and threw in
             production. Inertia resolves page components through the eager
             import.meta.glob in app.js; nothing needs to be requested per page. --}}
        @vite(['resources/js/app.js'])
        @inertiaHead
    </head>
    <body class="font-sans antialiased">
        @inertia
    </body>
</html>
