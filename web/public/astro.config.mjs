import { defineConfig } from 'astro/config';

export default defineConfig({
  site: 'https://www.omnilect.app',
  trailingSlash: 'never',
  build: {
    format: 'directory',
  },
});
