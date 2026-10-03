<?php

namespace App\Exceptions;

use RuntimeException;

/**
 * The SWRHAExpenseControl staff directory could not be read.
 *
 * This exists because a `?Authenticatable` return value cannot distinguish
 * "no such user" from "the directory is down", and conflating those two is a
 * real defect rather than a cosmetic one: `SWRHAUserProvider` used to swallow
 * the connection error and return `null`, so during a SQL Server outage a user
 * with entirely correct credentials was told *"These credentials do not match
 * our records."*
 *
 * The consequence is a support one, not a security one — nobody gets in who
 * should not — but it sends people to reset a password that was never wrong,
 * and on this deployment there is no monitoring, so that misleading message is
 * the only symptom anyone sees of a database outage.
 *
 * Thrown by the provider, caught by AuthenticatedSessionController. It must
 * NOT be caught anywhere that would turn it back into a credential failure.
 */
class DirectoryUnavailableException extends RuntimeException {}
