<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Factories\HasFactory;
use Illuminate\Foundation\Auth\User as Authenticatable;

class User extends Authenticatable
{
    use HasFactory;

    protected $fillable = [
        'name',
        'username',
        'employee_id',
        'password',
        'is_active',
        'sql_server_verified_at',
    ];

    protected $hidden = [
        'password',
        'remember_token',
    ];

    protected function casts(): array
    {
        return [
            'employee_id' => 'string',
            'is_active' => 'boolean',
            'sql_server_verified_at' => 'datetime',
        ];
    }
}
