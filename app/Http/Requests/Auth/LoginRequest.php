<?php

namespace App\Http\Requests\Auth;

use Illuminate\Foundation\Http\FormRequest;

/**
 * Validation only. Rate limiting is the `throttle:login` middleware on the
 * route, backed by the named limiter in AppServiceProvider (5/min per
 * username+IP). This class used to carry a second, parallel limiter check that
 * nothing ever incremented (no RateLimiter::hit() call existed anywhere), so it
 * could never fire — it was removed rather than left looking like protection.
 */
class LoginRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    public function rules(): array
    {
        return [
            'username' => ['required', 'string'],
            'password' => ['required', 'string'],
        ];
    }
}
