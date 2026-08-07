<script setup>
import LegalModal from './Legal/LegalModal.vue';
import PrivacyPolicyContent from './Legal/PrivacyPolicyContent.vue';
import TermsContent from './Legal/TermsContent.vue';

defineProps({
  privacy: { type: Boolean, default: false },
  terms: { type: Boolean, default: false },
});

const emit = defineEmits(['update:privacy', 'update:terms']);
</script>

<template>
  <LegalModal
    :open="privacy"
    title="Privacy Policy"
    icon="fas fa-shield-halved"
    label-id="privacy-policy-title"
    @close="emit('update:privacy', false)"
  >
    <PrivacyPolicyContent />
  </LegalModal>

  <LegalModal
    :open="terms"
    title="Terms and Conditions"
    icon="fas fa-file-contract"
    label-id="terms-conditions-title"
    @close="emit('update:terms', false)"
  >
    <TermsContent />
  </LegalModal>
</template>
