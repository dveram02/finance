<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>@yield('title', 'Error') — {{ config('app.name') }}</title>
    @vite(['resources/css/app.css'])
    <link rel="preconnect" href="https://fonts.bunny.net">
    <link href="https://fonts.bunny.net/css?family=figtree:400,500,600,700,800&display=swap" rel="stylesheet" />
    <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.0/css/all.min.css" crossorigin="anonymous" />
</head>
<body class="font-sans antialiased min-h-screen bg-gradient-to-br from-gray-50 via-blue-50 to-purple-50 flex flex-col items-center justify-center px-4">

    <!-- Brand header -->
    <div class="mb-10 text-center">
        <div class="inline-flex items-center gap-2.5 mb-1">
            <div class="w-8 h-8 bg-gradient-to-br from-blue-600 to-purple-600 rounded-lg flex items-center justify-center shadow-md">
                <i class="fas fa-warehouse text-white text-sm"></i>
            </div>
            <span class="text-xl font-bold text-gray-800">{{ config('app.name') }}</span>
        </div>
    </div>

    <!-- Error card -->
    <div class="w-full max-w-lg">
        @yield('card')

        <p class="text-center text-xs text-gray-400 mt-6">
            If this problem persists, please contact your system administrator.
        </p>
    </div>

</body>
</html>
