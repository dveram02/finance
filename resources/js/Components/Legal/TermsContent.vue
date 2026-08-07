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

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">1. Acceptance</h3>
    <p class="text-tx-body mb-4">
      By signing in to the SWRHA Finance Automation System (the "System") you agree to
      these Terms and Conditions and to the Privacy Policy. If you do not agree, do not
      use the System.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">2. Purpose of the System</h3>
    <p class="text-tx-body mb-4">
      The System is an internal reporting portal that presents SWRHA budget and
      expenditure information to authorised staff. It provides summary dashboards,
      budget allocations, and expenditure views by department, period and allocation
      line.
    </p>
    <p class="text-tx-body mb-4">
      The System is <strong>read-only</strong>. It does not create, approve, amend or
      delete any financial record, and it is not a requisition, procurement, payment or
      approval system.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">3. Accounts and Eligibility</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>Use of the System is limited to SWRHA employees and other individuals expressly authorised by SWRHA.</li>
      <li>Accounts are created and maintained in SWRHA's staff directory system, not within the System. There is no self-registration, password change or password reset here — direct such requests to the responsible department.</li>
      <li>Your account is personal to you. Do not share your credentials, and do not allow another person to use your session.</li>
    </ul>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">4. Access and Visibility</h3>
    <p class="text-tx-body mb-4">
      What you can see is determined by the departmental access assigned to your
      position in SWRHA's source systems. If no access has been assigned to you, the
      System will correctly show you no financial information; this is a matter of
      authorisation, not a fault, and can only be changed by the department responsible
      for granting access. You must not attempt to view information beyond the access
      you have been granted.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">5. Nature of the Information — No Reliance for Official Purposes</h3>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>Figures are drawn from SWRHA's finance systems and are refreshed periodically. They may not reflect transactions posted since the last refresh.</li>
      <li>The System presents defined categories of expenditure and allocation and deliberately excludes others; totals shown are therefore totals of what is presented, not of all SWRHA expenditure.</li>
      <li>All amounts are in Trinidad and Tobago Dollars (TTD) unless stated otherwise, and are reported on SWRHA's fiscal-year basis rather than the calendar year.</li>
      <li>The System is a management-reporting convenience. The source finance system remains the official record of account, and it governs in the event of any discrepancy. Do not rely on the System alone for statutory reporting, external submissions, audit responses or commitments of funds.</li>
    </ul>
    <p class="text-tx-body mb-4">
      If a figure appears incorrect, report it rather than acting on it. Corrections are
      made in the source system.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">6. Confidentiality</h3>
    <p class="text-tx-body mb-4">
      Information in the System is confidential SWRHA information. You may use it only
      for legitimate SWRHA business purposes, and you must not disclose, publish,
      forward or otherwise share it — including screenshots, exports and printed
      copies — with anyone not authorised to receive it. Your confidentiality
      obligations continue after your access ends.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">7. Acceptable Use</h3>
    <p class="text-tx-body mb-4">You must not:</p>
    <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
      <li>attempt to gain access to accounts, departments, data or functionality you are not authorised for;</li>
      <li>attempt to bypass, probe or test authentication, access controls or other security measures;</li>
      <li>interfere with, overload or disrupt the System, its infrastructure or its data sources;</li>
      <li>introduce malicious code, or use automated tools to scrape or bulk-extract information;</li>
      <li>copy, alter or reverse-engineer the System, or connect to its databases other than through the System;</li>
      <li>misrepresent information taken from the System, or use it for personal gain or any non-SWRHA purpose.</li>
    </ul>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">8. Monitoring</h3>
    <p class="text-tx-body mb-4">
      Use of the System is logged and may be monitored for security, operational and
      audit purposes, in accordance with SWRHA's information-security policies and
      applicable law.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">9. Availability</h3>
    <p class="text-tx-body mb-4">
      SWRHA aims to keep the System available during business hours but does not
      guarantee uninterrupted access. The System may be unavailable, or may show that
      financial information is temporarily unavailable, due to maintenance, data
      refreshes, upstream system outages, network conditions or circumstances beyond
      SWRHA's reasonable control. Features may be changed, added or withdrawn at any
      time.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">10. Limitation of Liability</h3>
    <p class="text-tx-body mb-4">
      The System is provided on an "as is" and "as available" basis, without warranty of
      any kind as to accuracy, completeness, timeliness or fitness for a particular
      purpose. To the fullest extent permitted by law, SWRHA accepts no liability for
      any loss or damage arising from use of, or reliance on, the System or the
      information it displays, or from its unavailability. Nothing in these terms limits
      any liability that cannot lawfully be limited.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">11. Suspension and Termination</h3>
    <p class="text-tx-body mb-4">
      Access is granted at SWRHA's discretion and may be suspended or withdrawn at any
      time, with or without notice — including where you breach these terms, where your
      employment or engagement ends, or where your account is marked inactive in the
      source directory system.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">12. Other Policies</h3>
    <p class="text-tx-body mb-4">
      These terms operate alongside SWRHA's information-security, data-protection,
      acceptable-use, financial and confidentiality policies. Where those policies
      impose stricter obligations, the stricter obligation applies.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">13. Changes to These Terms</h3>
    <p class="text-tx-body mb-4">
      SWRHA may amend these terms at any time. The effective date above indicates the
      current version, and continued use of the System after a change constitutes
      acceptance of the amended terms.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">14. Governing Law</h3>
    <p class="text-tx-body mb-4">
      These terms are governed by the laws of the Republic of Trinidad and Tobago, and
      any dispute arising from use of the System is subject to the exclusive
      jurisdiction of its courts.
    </p>

    <h3 class="font-display text-base font-bold text-tx-primary mt-7 mb-3">15. Contact</h3>
    <p class="text-tx-body">
      <strong>Email:</strong>
      <a :href="`mailto:${contactEmail}?subject=Finance Automation System — Terms Enquiry`" class="text-cyan-700 hover:text-cyan-800 dark:text-cyan-400 dark:hover:text-cyan-300">{{ contactEmail }}</a><br>
      <strong>Organisation:</strong> South West Regional Health Authority (SWRHA)
    </p>
  </div>
</template>
