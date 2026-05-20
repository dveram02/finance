import '../css/app.css';
import './bootstrap';
import '@/routeTracker';

import { createInertiaApp, Head, Link } from '@inertiajs/vue3';
import { resolvePageComponent } from 'laravel-vite-plugin/inertia-helpers';
import { createApp, h } from 'vue';
import { ZiggyVue } from '../../vendor/tightenco/ziggy';
import AppLayout from './Layouts/AppLayout.vue';

const appName = import.meta.env.VITE_APP_NAME || 'Laravel';

createInertiaApp({
    title: (title) => `${title} - ${appName}`,
     // imports Vue pages from resources/js/pages folder
    resolve: name => {

        // creates a map where keys are file paths and values are imported modules
        const pages = import.meta.glob('./Pages/**/*.vue', { eager: true })

        // returns the specified page from the pages folder
        // note we need to create the pages folder in the js folder
        let page = pages[`./Pages/${name}.vue`]

        // define the base layout conditionally for app
        if (name.startsWith('Auth/') || name === 'Welcome') {
            page.default.layout = undefined; // no layout
        } else {
            page.default.layout = page.default.layout ?? AppLayout;
        }

        return page;
    },
    setup({ el, App, props, plugin }) {
        return createApp({ render: () => h(App, props) })
            .use(plugin)
            .use(ZiggyVue)
            .component( 'Link', Link )
            .component( 'Head', Head )
            .mount(el);
    },
    progress: {
        color: '#4B5563',
    },
});
