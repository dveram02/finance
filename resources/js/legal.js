// Single source of truth for the policy documents' contact address and effective
// date, so neither is re-typed per component.
//
// Both documents are MODALS ONLY, opened from FooterBar via PolicyModals. There
// are no /privacy or /terms routes and no page components for them; an earlier
// version of this comment claimed there were. Do not add them unless asked.
//
// Bump the effective date whenever the policy text changes materially - the
// documents themselves say the date indicates the current version, and the
// Terms treat continued use after a change as acceptance of it.
export const LEGAL_CONTACT_EMAIL = 'technical.support@swrha.co.tt';
export const LEGAL_EFFECTIVE_DATE = 'October 2026';
