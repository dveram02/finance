<script setup>
/**
 * Loading veil for the ledger tables. Sits above the frozen header, totals row
 * and frozen columns, so its z-index has to clear the table's own stack.
 */
defineProps({
    show:  Boolean,
    label: { type: String, default: 'Loading expenditure' },
})
</script>

<template>
    <transition name="overlay">
        <div v-if="show"
            class="absolute inset-0 z-40 grid place-items-center bg-surface/70 backdrop-blur-[2px]">
            <div class="flex flex-col items-center gap-4">
                <div class="coin" aria-hidden="true">
                    <div class="coin__face coin__front">$</div>
                    <div class="coin__face coin__back">$</div>
                </div>
                <p class="text-[11px] font-semibold uppercase tracking-[0.22em] text-tx-subtle">
                    {{ label }}<span class="loading-dots"></span>
                </p>
            </div>
        </div>
    </transition>
</template>

<style scoped>
.overlay-enter-active,
.overlay-leave-active {
    transition: opacity 0.2s ease;
}
.overlay-enter-from,
.overlay-leave-to {
    opacity: 0;
}

.coin {
    position: relative;
    width: 58px;
    height: 58px;
    transform-style: preserve-3d;
    animation: coinFlip 1.5s cubic-bezier(0.45, 0, 0.55, 1) infinite,
               coinBob 1.5s ease-in-out infinite;
    filter: drop-shadow(0 10px 12px rgba(180, 83, 9, 0.28));
}

.coin__face {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    border-radius: 9999px;
    font-family: 'Playfair Display', Georgia, serif;
    font-weight: 700;
    font-size: 1.5rem;
    color: #7c2d12;
    backface-visibility: hidden;
    background:
        radial-gradient(circle at 34% 28%, #fffbeb 0%, #fde68a 26%, #f59e0b 62%, #d97706 84%, #b45309 100%);
    box-shadow:
        inset 0 2px 3px rgba(255, 255, 255, 0.65),
        inset 0 -4px 7px rgba(120, 53, 15, 0.5),
        inset 0 0 0 4px rgba(180, 83, 9, 0.28);   /* milled rim */
}

.coin__back { transform: rotateY(180deg); }

@keyframes coinFlip {
    0%   { transform: rotateY(0deg); }
    100% { transform: rotateY(360deg); }
}

@keyframes coinBob {
    0%, 100% { translate: 0 0; }
    50%      { translate: 0 -5px; }
}

.loading-dots::after {
    content: '';
    animation: loadingDots 1.4s steps(1, end) infinite;
}

@keyframes loadingDots {
    0%   { content: ''; }
    25%  { content: '.'; }
    50%  { content: '..'; }
    75%  { content: '...'; }
    100% { content: ''; }
}

@media (prefers-reduced-motion: reduce) {
    .coin { animation: coinFlip 2.4s linear infinite; }
    .loading-dots::after {
        animation: none;
        content: '…';
    }
}
</style>
