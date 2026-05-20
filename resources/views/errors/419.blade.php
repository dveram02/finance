@extends('errors._layout')

@section('title', '419 — Page Expired')

@section('card')
<div class="bg-white rounded-2xl shadow-xl border border-gray-100 overflow-hidden">
    <div class="h-1.5 w-full bg-gradient-to-r from-amber-400 to-orange-500"></div>
    <div class="px-8 py-10 text-center">
        <div class="mb-4 leading-none">
            <span class="text-9xl font-extrabold tracking-tight text-amber-100">419</span>
        </div>
        <div class="w-16 h-16 rounded-full bg-amber-50 flex items-center justify-center mx-auto mb-5 -mt-8 shadow-sm">
            <i class="fas fa-clock text-2xl text-amber-500"></i>
        </div>
        <h1 class="text-2xl font-bold text-gray-900 mb-3">Page Expired</h1>
        <p class="text-gray-500 text-sm leading-relaxed mb-8 max-w-sm mx-auto">
            Your session has expired. Please refresh the page and try again.
        </p>
        <div class="flex flex-col sm:flex-row items-center justify-center gap-3">
            <a href="javascript:location.reload()" class="inline-flex items-center justify-center gap-2 bg-gradient-to-r from-blue-600 to-indigo-600 text-white text-sm font-semibold px-6 py-2.5 rounded-lg shadow-md hover:shadow-lg transition-all duration-200 w-full sm:w-auto">
                <i class="fas fa-rotate-right text-xs"></i>
                Refresh Page
            </a>
            <a href="/dashboard" class="inline-flex items-center justify-center gap-2 bg-white text-gray-700 text-sm font-semibold px-6 py-2.5 rounded-lg border border-gray-200 hover:bg-gray-50 hover:border-gray-300 transition-all duration-200 w-full sm:w-auto">
                <i class="fas fa-home text-xs"></i>
                Back to Dashboard
            </a>
        </div>
    </div>
</div>
@endsection
