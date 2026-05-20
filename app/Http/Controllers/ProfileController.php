<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response;

class ProfileController extends Controller
{
    public function view(Request $request): Response
    {
        return Inertia::render('Profile/View Profile', [
            'user' => [
                'id'          => $request->user()->id,
                'name'        => $request->user()->name,
                'username'    => $request->user()->username,
                'employee_id' => $request->user()->employee_id,
            ],
        ]);
    }
}
