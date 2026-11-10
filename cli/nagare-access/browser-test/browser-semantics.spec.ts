import { expect, test, type BrowserContext, type Page } from '@playwright/test';

// What each engine does with a 307 that carries a new cookie (IR-41 AC-7). The
// table in docs/user/access.md is this file's result.

const origin = 'https://probe.example.test';
const other = 'https://probe-other.example.test';

async function cookieStored(context: BrowserContext, url: string) {
  const cookie = (await context.cookies(url)).find((c) => c.name === 'probe');
  return cookie?.value === 'new';
}

test.beforeEach(async ({ context, page }) => {
  // Firefox asks for this right after a page loads, and it would take the
  // rotation before the request under test.
  await page.route('**/favicon.ico', (route) => route.abort());
  await context.addCookies(
    [origin, other].map((url) => ({
      name: 'probe',
      value: 'old',
      url,
      secure: true,
      sameSite: 'Lax' as const,
    })),
  );
  await page.goto(`${origin}/page`);
});

type FetchResult = { status: number; redirected: boolean; type: string } | { error: string };

function runFetch(page: Page, url: string, init: RequestInit): Promise<FetchResult> {
  return page.evaluate(
    ([target, options]) =>
      fetch(target as string, options as RequestInit).then(
        (r) => ({ status: r.status, redirected: r.redirected, type: r.type }),
        (e) => ({ error: e.name }),
      ),
    [url, init] as const,
  );
}

function runEventSource(page: Page, url: string, withCredentials: boolean) {
  return page.evaluate(
    ([target, credentials]) =>
      new Promise<{ message: string } | { readyState: number }>((resolve) => {
        const source = new EventSource(target as string, {
          withCredentials: credentials as boolean,
        });
        source.onmessage = (event) => {
          source.close();
          resolve({ message: event.data });
        };
        source.onerror = () => {
          const readyState = source.readyState;
          source.close();
          resolve({ readyState });
        };
      }),
    [url, withCredentials] as const,
  );
}

const followed = { status: 200, redirected: true, type: 'basic' };
const followedCors = { status: 200, redirected: true, type: 'cors' };

test('document navigation', async ({ context, page }) => {
  const response = await page.goto(`${origin}/r/document`);
  expect(response?.status()).toBe(200);
  expect(page.url()).toBe(`${origin}/r/document`);
  expect(await cookieStored(context, origin)).toBe(true);
});

const sameOriginFetches: [string, RequestInit, FetchResult][] = [
  ['same-origin fetch, redirect follow', { redirect: 'follow' }, followed],
  ['same-origin fetch, mode same-origin', { mode: 'same-origin' }, followed],
  ['same-origin fetch, redirect error', { redirect: 'error' }, { error: 'TypeError' }],
  [
    'same-origin fetch, redirect manual',
    { redirect: 'manual' },
    { status: 0, redirected: false, type: 'opaqueredirect' },
  ],
];

for (const [name, init, expected] of sameOriginFetches) {
  test(name, async ({ context, page }) => {
    expect(await runFetch(page, '/r/fetch', init)).toEqual(expected);
    expect(await cookieStored(context, origin)).toBe(true);
  });
}

test('same-origin EventSource', async ({ context, page }) => {
  expect(await runEventSource(page, '/r/sse', false)).toEqual({ message: 'ready' });
  expect(await cookieStored(context, origin)).toBe(true);
});

test('cross-origin credentialed fetch, plain 307', async ({ context, page }) => {
  expect(await runFetch(page, `${other}/r/plain`, { credentials: 'include' })).toEqual({
    error: 'TypeError',
  });
  expect(await cookieStored(context, other)).toBe(true);
});

test('cross-origin credentialed fetch, 307 with CORS headers', async ({ context, page }) => {
  expect(await runFetch(page, `${other}/r/cors`, { credentials: 'include' })).toEqual(followedCors);
  expect(await cookieStored(context, other)).toBe(true);
});

test('cross-origin EventSource, plain 307', async ({ context, page }) => {
  expect(await runEventSource(page, `${other}/r/sse`, true)).toEqual({ readyState: 2 });
  expect(await cookieStored(context, other)).toBe(true);
});

test('cross-origin EventSource, 307 with CORS headers', async ({ context, page }) => {
  expect(await runEventSource(page, `${other}/r/sse-cors`, true)).toEqual({ message: 'ready' });
  expect(await cookieStored(context, other)).toBe(true);
});

test('fetch aborted while the retry is held upstream', async ({ context, page }) => {
  const result = await page.evaluate(
    () =>
      new Promise<string>((resolve) => {
        const controller = new AbortController();
        fetch('/r/held', { signal: controller.signal }).then(
          () => resolve('completed'),
          (e) => resolve(e.name),
        );
        setTimeout(() => controller.abort(), 1000);
      }),
  );
  expect(result).toBe('AbortError');
  expect(await cookieStored(context, origin)).toBe(true);
});

// The enforcer's raw handshake work is only useful if a browser keeps this.
test('WebSocket handshake with Set-Cookie on its 101', async ({ context, page }) => {
  const opened = await page.evaluate(
    (url) =>
      new Promise<string>((resolve) => {
        const socket = new WebSocket(url);
        socket.onopen = () => {
          socket.close();
          resolve('open');
        };
        socket.onerror = () => resolve('error');
      }),
    'wss://probe.example.test/ws',
  );
  expect(opened).toBe('open');
  expect(await cookieStored(context, origin)).toBe(true);
});
