<script setup>
import { LEGAL_CONTACT_EMAIL, LEGAL_EFFECTIVE_DATE } from '@/legal';

defineProps({
  contactEmail: { type: String, default: LEGAL_CONTACT_EMAIL },
  effectiveDate: { type: String, default: LEGAL_EFFECTIVE_DATE },
});
</script>

<template>
  <div class="prose prose-sm max-w-none dark:prose-invert">
    <p class="text-sm text-tx-muted mb-4">
      <strong>Effective Date:</strong> {{ effectiveDate }}
    </p>

    <p class="text-tx-body mb-4">
      This policy explains what information the SWRHA Finance Automation System
      (the "System") processes, why, and how it is protected. The System is an
      internal, read-only reporting portal for authorised SWRHA staff. It is not a
      public service and is not available to the general public.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">1. Information We Process</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li><strong>Account information:</strong> your username, employee identifier, display name and active/inactive status. This information originates in SWRHA's existing staff directory system; the System reads it to verify who you are and keeps a local copy so pages can be rendered.</li>
      <li><strong>Your password:</strong> checked against the staff directory when you sign in. If the password-change facility is enabled for your organisation, a new password you set on your profile page is written back to that same directory — the only information this System writes anywhere. Your current password must be supplied first. Password values are never written to application logs.</li>
      <li><strong>Access entitlements:</strong> the position, responsibility and department records that determine which financial information you are permitted to see.</li>
      <li><strong>Financial information:</strong> departmental budget allocations, expenditure, commitments and related account details. This is organisational financial data. It is not personal information about you, and the System does not hold client, patient or payroll records.</li>
      <li><strong>Session and technical records:</strong> a session cookie that keeps you signed in, and application logs recording events such as sign-in attempts, errors and data-source failures, together with the date, time and originating address.</li>
    </ul>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">2. What We Do Not Collect</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>No client, patient or clinical information.</li>
      <li>No salary, payroll or individual remuneration information — these are excluded from the System's data by design.</li>
      <li>No advertising, analytics, profiling or third-party tracking cookies. The only cookies set are those required for sign-in and security.</li>
      <li>No payment card or banking details.</li>
    </ul>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">3. How Information Is Used</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>To verify your identity at sign-in and confirm that your account remains active.</li>
      <li>To limit what you see to the departments your role is authorised for.</li>
      <li>To present budget, expenditure and allocation information on screen.</li>
      <li>To keep the System secure, diagnose faults, and support internal audit and accountability.</li>
    </ul>
    <p class="text-tx-body mb-4">
      Information is not used for any purpose unrelated to SWRHA's financial
      management and oversight, and is never sold or used for marketing.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">4. Where the Information Comes From</h3>
    <p class="text-tx-body mb-4">
      The System does not originate financial records. It reads from SWRHA's existing
      finance and staff systems and presents that information in a consolidated,
      read-only form. Figures are drawn from a periodically refreshed copy of the
      source data, so recently posted transactions may not yet appear. Those source
      systems are maintained by the <strong>Finance department</strong>, and corrections
      to any underlying record — allocations, transactions, account details and
      departmental access — are made there rather than in this System. The single
      exception is your own password, where the change facility is enabled.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">5. Access and Disclosure</h3>
    <p class="text-tx-body mb-4">
      Access is restricted to authorised SWRHA personnel and is scoped to the
      departments assigned to your position. Information is disclosed outside the
      System only:
    </p>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>to authorised SWRHA staff and internal or external auditors acting in their official capacity;</li>
      <li>where required by law, regulation, or lawful request; or</li>
      <li>to service providers engaged to host or maintain the System, bound by confidentiality obligations.</li>
    </ul>
    <p class="text-tx-body mb-4">
      Information is not shared with any other third party.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">6. Security</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>The System is hosted on SWRHA-controlled infrastructure and reachable only from the authority's network.</li>
      <li>Traffic is protected in transit using HTTPS/TLS.</li>
      <li>There is no public sign-up, self-registration, or facility to recover a forgotten password — accounts exist only because they were created in SWRHA's staff directory system. Where the password-change facility is enabled, it requires your current password and cannot be used to regain access to an account you are already locked out of.</li>
      <li>Your active status is re-checked against the source directory at regular intervals during a session; if your account is deactivated, access ends without waiting for you to sign out.</li>
      <li>Sign-in attempts are rate-limited, and all data pages are read-only — the System cannot alter financial records.</li>
    </ul>
    <p class="text-tx-body mb-4">
      No system can be guaranteed absolutely secure. If you suspect your credentials
      have been compromised or that someone has accessed information they should not,
      report it immediately using the contact below.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">7. Retention</h3>
    <p class="text-tx-body mb-4">
      Financial information is retained for as long as it is retained in the source
      finance system and in accordance with SWRHA's records-retention obligations.
      Account information is retained for the duration of your authorised access.
      Sessions expire after a period of inactivity, and application logs are retained
      only as long as needed for security, troubleshooting and audit.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">8. Your Rights</h3>
    <p class="text-tx-body mb-4">
      You may view the account details held about you on your profile page, ask for a
      correction to those details, ask what departmental access has been assigned to
      you, and raise a privacy concern. Accounts are managed by the <strong>Finance
      department</strong> in SWRHA's source systems rather than in this System, so
      requests are actioned there; contact the address below and it will be directed to
      them.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">9. Contact</h3>
    <p class="text-tx-body mb-4">
      <strong>Email:</strong>
      <a :href="`mailto:${contactEmail}?subject=Finance Automation System — Privacy Enquiry`" class="text-cyan-700 hover:text-cyan-800 dark:text-cyan-400 dark:hover:text-cyan-300">{{ contactEmail }}</a><br>
      <strong>Organisation:</strong> South West Regional Health Authority (SWRHA)
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">10. Changes to This Policy</h3>
    <p class="text-tx-body">
      This policy may be updated from time to time. The effective date above indicates
      the current version, and material changes will be communicated to users through
      the System or by internal notice.
    </p>
  </div>
</template>
