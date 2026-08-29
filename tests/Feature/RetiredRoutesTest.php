<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Route;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

/**
 * The URLs retired when Department Expenditure took the /monthly-expenditure
 * name and Allocation Line Expenditure became /variance.
 *
 * They are REMOVED, not redirected — a deliberate decision, so the only thing
 * that can prove it stayed removed is a test. Nothing else in the suite would
 * notice a well-meaning redirect being added back later.
 *
 * Fully offline: a URL with no route never reaches the `auth` or `active.user`
 * middleware, so neither SQL Server is touched.
 */
class RetiredRoutesTest extends TestCase
{
    use RefreshDatabase;

    /** @return array<string,array<int,string>> */
    public static function retiredUrls(): array
    {
        return [
            'department expenditure' => ['/department-expenditure'],
            'allocation line expenditure' => ['/allocation-line-expenditure'],
        ];
    }

    #[DataProvider('retiredUrls')]
    public function test_a_retired_url_is_gone_for_a_signed_in_user(string $url): void
    {
        $this->actingAs(User::factory()->create())
            ->get($url)
            ->assertNotFound();
    }

    /**
     * 404, NOT a redirect to /login. The route does not exist, so the auth
     * middleware never runs — do not copy the assertRedirect('/login') pattern
     * the live page tests use.
     */
    #[DataProvider('retiredUrls')]
    public function test_a_retired_url_is_gone_for_a_guest(string $url): void
    {
        $this->get($url)->assertNotFound();
    }

    public function test_the_retired_route_names_are_not_registered(): void
    {
        $names = array_keys(Route::getRoutes()->getRoutesByName());

        $this->assertNotContains('department-expenditure.index', $names);
        $this->assertNotContains('allocation-line-expenditure.index', $names);

        // And the names that replaced them are.
        $this->assertContains('monthly-expenditure.index', $names);
        $this->assertContains('variance.index', $names);
    }
}
