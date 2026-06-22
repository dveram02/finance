<script setup>
import { usePage } from '@inertiajs/vue3';
import { onMounted, ref } from 'vue';

const currentYear = ref(new Date().getFullYear());
const showPrivacyModal = ref(false);
const showTermsModal = ref(false);

const page = usePage();
const version = page.props.appVersion || '';

onMounted(() => {
  const el = document.querySelector('#copyright-year');
  if (el) {
    el.textContent = currentYear.value;
  }
});

const openSupport = () => {
  window.location.href = 'mailto:bharath.ramkissoon@swrha.co.tt?subject=Client Feedback System Support Request';
};

const closePrivacyModal = () => {
  showPrivacyModal.value = false;
};

const closeTermsModal = () => {
  showTermsModal.value = false;
};

// Close modal on escape key
const handleEscape = (e) => {
  if (e.key === 'Escape') {
    showPrivacyModal.value = false;
    showTermsModal.value = false;
  }
};

onMounted(() => {
  document.addEventListener('keydown', handleEscape);
});
</script>

<template>
  <footer class="bg-surface/80 backdrop-blur-sm border-t border-line/50 mt-auto transition-colors duration-300">
    <div class="max-w-full px-5 sm:px-7 py-2.5">
      <!-- Single row with all content -->
      <div class="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-2 text-xs">
        <!-- Left: Copyright -->
        <div class="text-tx-muted flex-shrink-0">
          © <span id="copyright-year">{{ currentYear }}</span> SWRHA. All Rights Reserved.
        </div>

        <!-- Center: Quick links with icons -->
        <div class="flex items-center gap-4 text-tx-subtle">
          <button
            @click="showPrivacyModal = true"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-shield-alt text-xs"></i>
            <span>Privacy</span>
          </button>
          <span class="text-tx-subtle">•</span>
          <button
            @click="showTermsModal = true"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-file-contract text-xs"></i>
            <span>Terms</span>
          </button>
          <span class="text-tx-subtle">•</span>
          <button
            @click="openSupport"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-life-ring text-xs"></i>
            <span>Support</span>
          </button>
        </div>

        <!-- Right: Version, Status & Developer Attribution -->
        <div class="flex items-center gap-4 text-xs flex-shrink-0">
          <span class="flex items-center gap-1.5 text-tx-subtle">
            <i class="fas fa-code text-blue-500"></i>
            <span>v{{ version }}</span>
          </span>
          <div class="flex items-center gap-1.5 px-2.5 py-1 bg-green-50 rounded-full border border-green-200 dark:bg-green-900/20 dark:border-green-800">
            <div class="w-1.5 h-1.5 bg-green-500 rounded-full animate-pulse"></div>
            <i class="fas fa-server text-green-600 dark:text-green-400 text-xs"></i>
            <span class="font-medium text-green-700 dark:text-green-400">Online</span>
          </div>
          <span class="hidden sm:flex items-center gap-1.5 text-tx-subtle">
            <i class="fas fa-handshake text-teal-500"></i>
            <span>In Collaboration with <span class="font-medium text-teal-600 dark:text-teal-400">Finance and ICT</span></span>
          </span>
          <a
            href="https://tt.linkedin.com/in/bharathramkissoon"
            target="_blank"
            rel="noopener noreferrer"
            class="hidden sm:flex items-center gap-1.5 text-tx-subtle hover:text-purple-600 dark:hover:text-purple-400 transition-colors duration-200 group"
          >
            <i class="fas fa-laptop-code text-purple-500 group-hover:scale-110 transition-transform duration-200"></i>
            <span>Developed by <span class="font-medium text-purple-600 group-hover:underline">Bharath Ramkissoon</span></span>
          </a>
        </div>
      </div>

      <!-- Mobile Attribution -->
      <div class="sm:hidden mt-2 flex flex-col items-center gap-1.5 text-center text-xs">
        <span class="inline-flex items-center gap-1.5 text-tx-subtle">
          <i class="fas fa-handshake text-teal-500"></i>
          <span>In Collaboration with <span class="font-medium text-teal-600 dark:text-teal-400">Finance and ICT</span></span>
        </span>
        <a
          href="https://tt.linkedin.com/in/bharathramkissoon"
          target="_blank"
          rel="noopener noreferrer"
          class="inline-flex items-center gap-1.5 text-tx-subtle hover:text-purple-600 dark:hover:text-purple-400 transition-colors duration-200"
        >
          <i class="fas fa-laptop-code text-purple-500"></i>
          <span>Developed by <span class="font-medium text-purple-600 hover:underline">Bharath Ramkissoon</span></span>
        </a>
      </div>
    </div>

    <!-- Minimal gradient accent -->
    <div class="h-0.5 bg-gradient-to-r from-blue-500 via-purple-500 to-pink-500"></div>
  </footer>

  <!-- Privacy Policy Modal -->
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="showPrivacyModal"
        class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm"
        @click.self="closePrivacyModal"
      >
        <div class="bg-surface rounded-xl shadow-2xl max-w-3xl w-full max-h-[85vh] overflow-hidden flex flex-col border border-line">
          <!-- Modal Header -->
          <div class="flex items-center justify-between px-6 py-4 border-b border-line bg-gradient-to-r from-blue-50 to-purple-50 dark:from-blue-950/40 dark:to-purple-950/40">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 bg-blue-100 dark:bg-blue-900/30 rounded-lg flex items-center justify-center">
                <i class="fas fa-shield-alt text-blue-600 dark:text-blue-400 text-lg"></i>
              </div>
              <h2 class="text-xl font-bold text-tx-primary">Privacy Policy</h2>
            </div>
            <button
              @click="closePrivacyModal"
              class="w-8 h-8 flex items-center justify-center rounded-lg hover:bg-surface-4 transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <i class="fas fa-times text-tx-subtle"></i>
            </button>
          </div>

          <!-- Modal Body -->
          <div class="px-6 py-4 overflow-y-auto flex-1 text-tx-body">
            <div class="prose prose-sm max-w-none dark:prose-invert">
              <p class="text-sm text-tx-muted mb-4">
                <strong>Effective Date:</strong> December 2024
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">1. Information We Collect</h3>
              <p class="text-tx-body mb-4">
                The SWRHA Client Feedback Management System collects and processes the following information:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li><strong>User Information:</strong> Name, email address, role, assigned facilities, clusters, and departments</li>
                <li><strong>Feedback Data:</strong> Client feedback submissions, tracking numbers, urgency levels, feedback types, and resolution status</li>
                <li><strong>Issue Records:</strong> Related issues, non-compliance categories, root causes, assigned personnel, and verification status</li>
                <li><strong>System Logs:</strong> Audit trails, login attempts, and system activity for security and operational purposes</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">2. How We Use Your Information</h3>
              <p class="text-tx-body mb-4">
                We use collected information to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Manage and process client feedback and quality improvement initiatives</li>
                <li>Enable role-based access control and ensure data security</li>
                <li>Generate reports, analytics, and operational insights for quality management</li>
                <li>Maintain system integrity and conduct audits when necessary</li>
                <li>Communicate with users regarding feedback status, updates, and system notifications</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">3. Data Security</h3>
              <p class="text-tx-body mb-4">
                SWRHA implements industry-standard security measures including:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Encrypted data transmission using HTTPS/TLS protocols</li>
                <li>Secure authentication with optional two-factor authentication (2FA)</li>
                <li>Role-based access controls limiting data visibility based on user permissions</li>
                <li>Regular security audits and system monitoring</li>
                <li>Data backup and disaster recovery procedures</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">4. Data Retention</h3>
              <p class="text-tx-body mb-4">
                Feedback and issue records are retained in accordance with SWRHA's data retention policies and applicable healthcare regulations. Personal user data is retained for the duration of employment or system access authorization.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">5. User Rights</h3>
              <p class="text-tx-body mb-4">
                Authorized users have the right to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Access their personal information and profile settings</li>
                <li>Update their account details and security preferences</li>
                <li>Request data corrections or clarifications</li>
                <li>Report privacy concerns to system administrators</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">6. Disclosure of Information</h3>
              <p class="text-tx-body mb-4">
                SWRHA does not share user data with third parties except:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>When required by law or legal process</li>
                <li>To authorized personnel within SWRHA for legitimate quality management purposes</li>
                <li>With explicit user consent for specific purposes</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">7. Contact Information</h3>
              <p class="text-tx-body mb-4">
                For privacy-related inquiries or concerns, please contact:
              </p>
              <p class="text-tx-body mb-4">
                <strong>Email:</strong> <a href="mailto:user@example.com" class="text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300">user@example.com</a><br>
                <strong>Organization:</strong> South West Regional Health Authority (SWRHA)
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">8. Policy Updates</h3>
              <p class="text-tx-body">
                This privacy policy may be updated periodically. Users will be notified of significant changes through system notifications or email communications.
              </p>
            </div>
          </div>

          <!-- Modal Footer -->
          <div class="px-6 py-4 border-t border-line bg-surface-2 flex justify-end">
            <button
              @click="closePrivacyModal"
              class="px-6 py-2 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 transition-colors focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>

  <!-- Terms and Conditions Modal -->
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="showTermsModal"
        class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/50 backdrop-blur-sm"
        @click.self="closeTermsModal"
      >
        <div class="bg-surface rounded-xl shadow-2xl max-w-3xl w-full max-h-[85vh] overflow-hidden flex flex-col border border-line">
          <!-- Modal Header -->
          <div class="flex items-center justify-between px-6 py-4 border-b border-line bg-gradient-to-r from-purple-50 to-pink-50 dark:from-purple-950/40 dark:to-pink-950/40">
            <div class="flex items-center gap-3">
              <div class="w-10 h-10 bg-purple-100 dark:bg-purple-900/30 rounded-lg flex items-center justify-center">
                <i class="fas fa-file-contract text-purple-600 dark:text-purple-400 text-lg"></i>
              </div>
              <h2 class="text-xl font-bold text-tx-primary">Terms and Conditions</h2>
            </div>
            <button
              @click="closeTermsModal"
              class="w-8 h-8 flex items-center justify-center rounded-lg hover:bg-surface-4 transition-colors focus:outline-none focus:ring-2 focus:ring-purple-500"
            >
              <i class="fas fa-times text-tx-subtle"></i>
            </button>
          </div>

          <!-- Modal Body -->
          <div class="px-6 py-4 overflow-y-auto flex-1 text-tx-body">
            <div class="prose prose-sm max-w-none dark:prose-invert">
              <p class="text-sm text-tx-muted mb-4">
                <strong>Effective Date:</strong> December 2024
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">1. Acceptance of Terms</h3>
              <p class="text-tx-body mb-4">
                By accessing and using the South West Regional Health Authority (SWRHA) Client Feedback Management System, you agree to be bound by these Terms and Conditions. If you do not agree to these terms, you must not access or use the system.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">2. System Purpose</h3>
              <p class="text-tx-body mb-4">
                This system is designed to facilitate the collection, management, tracking, and resolution of client feedback to support SWRHA's quality improvement initiatives. The system enables authorized personnel to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Record and categorize client feedback and complaints</li>
                <li>Manage related issues and non-compliance records</li>
                <li>Track resolution and verification workflows</li>
                <li>Generate reports and analytics for quality management</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">3. User Responsibilities</h3>
              <p class="text-tx-body mb-4">
                As an authorized user, you agree to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li><strong>Maintain Confidentiality:</strong> Keep your login credentials secure and not share your account with unauthorized persons</li>
                <li><strong>Use Appropriately:</strong> Use the system only for legitimate SWRHA business purposes related to quality management</li>
                <li><strong>Data Accuracy:</strong> Enter accurate, complete, and truthful information when submitting or updating feedback and issue records</li>
                <li><strong>Comply with Policies:</strong> Adhere to SWRHA's data protection, privacy, and information security policies</li>
                <li><strong>Report Issues:</strong> Immediately report any suspected security breaches, unauthorized access, or system vulnerabilities</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">4. Access and Permissions</h3>
              <p class="text-tx-body mb-4">
                User access levels and permissions are determined by assigned roles:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li><strong>Admin:</strong> Full system access including user management and configuration</li>
                <li><strong>Quality Officer:</strong> Can add feedback and manage issues within assigned clusters</li>
                <li><strong>Quality Coordinator:</strong> Extended permissions including issue verification within assigned clusters</li>
                <li><strong>Quality Manager:</strong> Organization-wide editing capabilities until records are verified</li>
                <li><strong>Board Member:</strong> Limited access to assigned feedback records only</li>
                <li><strong>General User:</strong> Profile and security settings access only</li>
                <li><strong>Management:</strong> Access to assigned issues and scoped reports</li>
              </ul>
              <p class="text-tx-body mb-4">
                Users must not attempt to access data or functionality beyond their authorized permissions.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">5. Data Integrity and Audit</h3>
              <p class="text-tx-body mb-4">
                All user activities within the system are logged for audit and security purposes. SWRHA reserves the right to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Monitor system usage to ensure compliance with these terms</li>
                <li>Review audit logs for quality assurance and security investigations</li>
                <li>Suspend or revoke access for users who violate these terms</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">6. Prohibited Activities</h3>
              <p class="text-tx-body mb-4">
                Users must not:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Attempt to gain unauthorized access to any part of the system</li>
                <li>Interfere with or disrupt the system's operation or security</li>
                <li>Upload malicious code, viruses, or harmful content</li>
                <li>Extract or scrape data for unauthorized purposes</li>
                <li>Misrepresent or falsify feedback or issue information</li>
                <li>Use the system for personal gain or non-SWRHA purposes</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">7. System Availability</h3>
              <p class="text-tx-body mb-4">
                While SWRHA strives to maintain continuous system availability, we do not guarantee uninterrupted access. The system may be temporarily unavailable due to:
              </p>
              <ul class="list-disc pl-6 text-tx-body space-y-2 mb-4">
                <li>Scheduled maintenance and updates</li>
                <li>Emergency repairs or security patches</li>
                <li>Circumstances beyond SWRHA's reasonable control</li>
              </ul>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">8. Limitation of Liability</h3>
              <p class="text-tx-body mb-4">
                SWRHA provides this system "as is" and makes no warranties regarding its fitness for any particular purpose. SWRHA is not liable for any indirect, incidental, or consequential damages arising from system use.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">9. Termination</h3>
              <p class="text-tx-body mb-4">
                SWRHA reserves the right to suspend or terminate user access at any time, with or without notice, for violations of these terms or for any other reason deemed necessary for system security or organizational needs.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">10. Changes to Terms</h3>
              <p class="text-tx-body mb-4">
                SWRHA may modify these Terms and Conditions at any time. Continued use of the system after changes constitutes acceptance of the modified terms. Users will be notified of significant changes through system notifications.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">11. Governing Law</h3>
              <p class="text-tx-body mb-4">
                These terms are governed by the laws of Trinidad and Tobago. Any disputes arising from system use shall be subject to the exclusive jurisdiction of Trinidad and Tobago courts.
              </p>

              <h3 class="text-lg font-semibold text-tx-primary mt-6 mb-3">12. Contact Information</h3>
              <p class="text-tx-body">
                For questions about these Terms and Conditions, please contact:<br>
                <strong>Email:</strong> <a href="mailto:user@example.com" class="text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300">user@example.com</a><br>
                <strong>Organization:</strong> South West Regional Health Authority (SWRHA)
              </p>
            </div>
          </div>

          <!-- Modal Footer -->
          <div class="px-6 py-4 border-t border-line bg-surface-2 flex justify-end">
            <button
              @click="closeTermsModal"
              class="px-6 py-2 bg-purple-600 text-white font-medium rounded-lg hover:bg-purple-700 transition-colors focus:outline-none focus:ring-2 focus:ring-purple-500 focus:ring-offset-2"   >
          Close
        </button>
      </div>
    </div>
  </div>
</Transition>
  </Teleport>
</template>
<style scoped>
/* Smooth link transitions */
button {
  position: relative;
}

button::after {
  content: '';
  position: absolute;
  bottom: -2px;
  left: 0;
  width: 0;
  height: 1px;
  background: linear-gradient(to right, #3b82f6, #a855f7);
  transition: width 0.3s ease;
}

button:hover::after {
  width: 100%;
}

@keyframes pulse {
  0%, 100% {
    opacity: 1;
  }
  50% {
    opacity: 0.5;
  }
}

.animate-pulse {
  animation: pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite;
}

/* Modal transitions */
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.3s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-active .bg-white,
.modal-leave-active .bg-white {
  transition: transform 0.3s ease;
}

.modal-enter-from .bg-white,
.modal-leave-to .bg-white {
  transform: scale(0.95);
}
</style>
