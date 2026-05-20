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
            'status'      => session('status'),
            'oldUsername' => old('username'),
        ]);
    }

    public function store(LoginRequest $request): RedirectResponse
    {
        $request->ensureIsNotRateLimited();

        $username = $request->string('username')->toString();
        $password = $request->string('password')->toString();

        $credentialsValid = Auth::validate([
            'username' => $username,
            'password' => $password,
        ]);

        if ($credentialsValid) {
            $user = Auth::getProvider()->retrieveByCredentials([
                'username' => $username,
                'password' => $password,
            ]);

            if ($user && !$user->is_active) {
                return redirect()->route('login')
                    ->withInput($request->only('username'))
                    ->with('error', 'Your account has been deactivated. Please contact an administrator.');
            }

            if ($user) {
                Auth::login($user, $request->boolean('remember'));
                $request->session()->regenerate();

                return redirect()->intended(route('dashboard', absolute: false));
            }
        }

        return redirect()->route('login')
            ->withInput($request->only('username'))
            ->withErrors(['username' => __('auth.failed')]);
    }

    public function destroy(Request $request): RedirectResponse
    {
        Auth::guard('web')->logout();
        $request->session()->invalidate();
        $request->session()->regenerateToken();

        return redirect('/');
    }
}
