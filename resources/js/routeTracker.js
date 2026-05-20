import { ref } from 'vue'
import { router } from '@inertiajs/vue3'

export const previousUrl = ref(null)
export const currentUrl  = ref(null)

router.on('navigate', (event) => {
    previousUrl.value = currentUrl.value
    currentUrl.value  = event.detail.page.url
})
