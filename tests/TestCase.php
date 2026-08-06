<?php

namespace Tests;

use Illuminate\Foundation\Testing\TestCase as BaseTestCase;

abstract class TestCase extends BaseTestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        // Feature tests render real Blade + Inertia responses, which would
        // otherwise resolve the Vite manifest and fail on a machine that has
        // not run `npm run build` (or whose public/build predates a change to
        // the @vite() entry list). Nothing here asserts on asset URLs.
        $this->withoutVite();
    }
}
