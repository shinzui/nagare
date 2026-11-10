import { defineConfig, devices } from '@playwright/test';

// One worker: the harness listens on fixed ports and the tests measure a shared
// session store. Isolation between attempts comes from per-attempt cases.
export default defineConfig({
  testDir: '.',
  testMatch: '*.spec.ts',
  workers: 1,
  timeout: 30_000,
  reporter: 'list',
  globalSetup: './tls-proxy.ts',
  use: {
    ignoreHTTPSErrors: true,
    proxy: { server: 'http://127.0.0.1:18790' },
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox', use: { ...devices['Desktop Firefox'] } },
    { name: 'webkit', use: { ...devices['Desktop Safari'] } },
  ],
  webServer: {
    command: 'cabal run -v0 test:nagare-access-browser-harness',
    cwd: '..',
    url: 'http://127.0.0.1:18781/healthz',
    env: { NAGARE_ACCESS_BROWSER_HARNESS: '1' },
    timeout: 300_000,
    reuseExistingServer: false,
    stdout: 'pipe',
    stderr: 'pipe',
    // Haskell runs its cleanups, which remove the temporary database, on an
    // interrupt and not on SIGTERM.
    gracefulShutdown: { signal: 'SIGINT', timeout: 10_000 },
  },
});
