<?php

namespace App\Http\Controllers\Auth;

use App\Http\Controllers\Controller;
use App\Http\Requests\Auth\LoginRequest;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Inertia\Inertia;
use Inertia\Response;

class AuthenticatedSessionController extends Controller
{
    public function create(): Response
    {
        return Inertia::render('Auth/Login', [
            'status' => session('status'),
            'oldUsername' => old('username'),
        ]);
    }

    /**
     * Attempt count matters here: the auth SQL Server is remote and shared, so
     * this is ONE Auth::attempt() (= one directory lookup), not a validate()
     * followed by a second retrieveByCredentials().
     *
     * An inactive account authenticates and is then logged straight back out,
     * rather than being rejected as a bad credential — the provider returns it
     * deliberately so this message is reachable. Telling someone with a correct
     * password that their credentials are wrong leaves them retrying forever.
     */
    public function store(LoginRequest $request): RedirectResponse
    {
        $credentials = [
            'username' => $request->string('username')->toString(),
            'password' => $request->string('password')->toString(),
        ];

        if (! Auth::attempt($credentials, $request->boolean('remember'))) {
            return redirect()->route('login')
                ->withInput($request->only('username'))
                ->withErrors(['username' => __('auth.failed')]);
        }

        if (! $request->user()->is_active) {
            Auth::logout();
            $request->session()->invalidate();
            $request->session()->regenerateToken();

            return redirect()->route('login')
                ->withInput($request->only('username'))
                ->with('error', 'Your account has been deactivated. Please contact an administrator.');
        }

        $request->session()->regenerate();

        return redirect()->intended(route('dashboard', absolute: false));
    }

    public function destroy(Request $request): RedirectResponse
    {
        Auth::guard('web')->logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return redirect('/');
    }
}
