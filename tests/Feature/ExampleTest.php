<?php

namespace Tests\Feature;

use Tests\TestCase;

class ExampleTest extends TestCase
{
    public function test_root_redirects_to_dashboard(): void
    {
        // Root route always redirects to dashboard (auth middleware then
        // redirects unauthenticated users onward to login from there).
        $response = $this->get('/');
        $response->assertRedirect('/dashboard');
    }
}
