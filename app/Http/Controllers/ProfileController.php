<?php

namespace App\Http\Controllers;

use App\Services\DirectoryPasswordService;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Validation\ValidationException;
use Inertia\Inertia;
use Inertia\Response;

class ProfileController extends Controller
{
    // =========================================================================
    // Constructor
    // =========================================================================

    public function __construct(
        private readonly DirectoryPasswordService $directoryPasswords,
    ) {}

    // =========================================================================
    // view() — read-only profile
    // =========================================================================

    public function view(Request $request): Response
    {
        return Inertia::render('Profile/View Profile', [
            'user' => [
                'id' => $request->user()->id,
                'name' => $request->user()->name,
                'username' => $request->user()->username,
                'employee_id' => $request->user()->employee_id,
            ],
            'canChangePassword' => $this->directoryPasswords->isEnabled(),
        ]);
    }

    // =========================================================================
    // updatePassword() — the only write in this application
    // =========================================================================

    public function updatePassword(Request $request): RedirectResponse
    {
        $data = $request->validate([
            // NEVER add Laravel's built-in 'current_password' RULE here. It
            // shares its name with this field but validates against the local
            // users.password hash, which holds Hash::make(Str::random(40)) and
            // authenticates nothing — it would reject 100% of attempts with a
            // perfectly reasonable-looking message. The real check lives in
            // DirectoryPasswordService and nowhere else.
            'current_password' => ['required', 'string'],
            'password' => [
                'required',
                'string',
                'min:'.DirectoryPasswordService::MIN_LENGTH,
                'max:'.DirectoryPasswordService::MAX_LENGTH,
                // Printable ASCII only. See the constant's own docblock: it is
                // a lockout guard rather than a style rule, and the /D modifier
                // baked into it is load-bearing. Ordered BEFORE different and
                // confirmed so someone pasting a smart quote gets the character
                // message rather than a mismatch message.
                'regex:'.DirectoryPasswordService::PRINTABLE_ASCII,
                'different:current_password',
                'confirmed',
            ],
        ], [
            'password.regex' => 'Your new password may only contain letters, numbers, spaces and standard keyboard symbols.',
            'password.different' => 'Your new password must be different from your current password.',
            'password.confirmed' => 'The new password and its confirmation do not match.',
            'password.min' => 'Your new password must be at least '.DirectoryPasswordService::MIN_LENGTH.' characters.',
            'password.max' => 'Your new password may not be longer than '.DirectoryPasswordService::MAX_LENGTH.' characters.',
        ]);

        try {
            $this->directoryPasswords->change(
                $request->user(),
                $data['current_password'],
                $data['password'],
            );
        } catch (ValidationException $e) {
            // A deliberate deviation from the house pattern's
            // back()->with('error', ...) shape: every one of these failures is
            // attributable to a single field, and a flat flash would strand the
            // message away from the input the user has to correct. One signal
            // per failure — do not also flash an error here.
            return back()->withErrors($e->errors());
        }

        $request->session()->regenerate();

        return redirect()->route('profile.view')
            ->with('success', 'Your password has been changed.');
    }
}
