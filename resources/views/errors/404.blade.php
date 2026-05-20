@extends('errors._layout')

@section('title', '404 — Page Not Found')

@section('card')
<div class="bg-white rounded-2xl shadow-xl border border-gray-100 overflow-hidden">
    <div class="h-1.5 w-full bg-gradient-to-r from-blue-500 to-indigo-600"></div>
    <div class="px-8 py-10 text-center">
        <div class="mb-4 leading-none">
            <span class="text-9xl font-extrabold tracking-tight text-blue-100">404</span>
        </div>
        <div class="w-16 h-16 rounded-full bg-blue-50 flex items-center justify-center mx-auto mb-5 -mt-8 shadow-sm">
            <i class="fas fa-search text-2xl text-blue-500"></i>
        </div>
        <h1 class="text-2xl font-bold text-gray-900 mb-3">Page Not Found</h1>
        <p class="text-gray-500 text-sm leading-relaxed mb-8 max-w-sm mx-auto">
            The page you're looking for doesn't exist or may have been moved.
        </p>
        <div class="flex flex-col sm:flex-row items-center justify-center gap-3">
            <a href="/dashboard" class="inline-flex items-center justify-center gap-2 bg-gradient-to-r from-blue-600 to-indigo-600 text-white text-sm font-semibold px-6 py-2.5 rounded-lg shadow-md hover:shadow-lg transition-all duration-200 w-full sm:w-auto">
                <i class="fas fa-home text-xs"></i>
                Back to Dashboard
            </a>
            <a href="javascript:history.back()" class="inline-flex items-center justify-center gap-2 bg-white text-gray-700 text-sm font-semibold px-6 py-2.5 rounded-lg border border-gray-200 hover:bg-gray-50 hover:border-gray-300 transition-all duration-200 w-full sm:w-auto">
                <i class="fas fa-arrow-left text-xs"></i>
                Go Back
            </a>
        </div>
    </div>
</div>
@endsection
