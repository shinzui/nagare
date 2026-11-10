import { test as base, expect, type BrowserContext, type Page } from '@playwright/test';

// The enforcer in real browsers against a real Shomei (IR-41 AC-6). The control
// scenario runs the same abort with the redirect off and must end the session,
// which is what proves the rest detects the defect.

const control = 'http://127.0.0.1:18781';
const upstream = 'http://127.0.0.1:18783';
const coalescerWindowMs = 2_000;
const settleMs = coalescerWindowMs + 3_000;
const cleanupBudgetMs = 10_000;

type User = { login: string; password: string; userId: string };

async function api<T>(method: string, path: string): Promise<T> {
  const response = await fetch(`${control}${path}`, { method });
  if (!response.ok) throw new Error(`${method} ${path}: ${response.status}`);
  return response.json() as Promise<T>;
}

const newCase = async () => (await api<{ id: string }>('POST', '/cases')).id;
const release = (id: string) => api('POST', `/release?case=${id}`);
const deleteCase = (id: string) => api('DELETE', `/cases/${id}`);
const counts = (id: string, path: string) =>
  api<{ count: number; arrived: boolean; released: boolean }>(
    'GET',
    `/counts?case=${id}&path=${encodeURIComponent(path)}`,
  );
const reuseAlarms = async (user: User) =>
  (await api<{ count: number }>('GET', `/reuse-alarms?user=${user.userId}`)).count;

function withinBudget(work: Promise<unknown>) {
  return Promise.race([
    work,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error('cleanup ran out of its budget')), cleanupBudgetMs),
    ),
  ]);
}

const test = base.extend<{ harnessCase: string }>({
  // A fresh case for every attempt, retries and each engine included. Cleanup
  // closes the context first, so a held response released afterwards has nobody
  // left to change the result for.
  harnessCase: async ({ context }, use) => {
    const id = await newCase();
    try {
      await use(id);
    } finally {
      await withinBudget(
        (async () => {
          await context.close();
          await release(id);
          await deleteCase(id);
        })(),
      );
    }
  },
  page: async ({ page }, use) => {
    await page.route('**/favicon.ico', (route) => route.abort());
    await use(page);
  },
});

async function signIn(page: Page, host: string): Promise<User> {
  const user = await api<User>('POST', '/users');
  await page.goto(`https://${host}/_nagare/login?rd=%2F`);
  await page.fill('input[name=loginId]', user.login);
  await page.fill('input[name=password]', user.password);
  await Promise.all([page.waitForURL(`https://${host}/`), page.click('button[type=submit]')]);
  return user;
}

async function refreshCookie(context: BrowserContext, host: string) {
  const cookie = (await context.cookies(`https://${host}/`)).find(
    (c) => c.name === 'nagare_refresh',
  );
  if (!cookie) throw new Error('no refresh cookie');
  return cookie.value;
}

// Exactly what the enforcer sees for an expired access token.
const expireAccess = (context: BrowserContext) => context.clearCookies({ name: 'nagare_session' });

function startHeldFetch(page: Page, url: string) {
  return page.evaluate((target) => {
    const scope = window as unknown as Record<string, unknown>;
    const controller = new AbortController();
    scope.heldController = controller;
    scope.heldOutcome = fetch(target, { signal: controller.signal }).then(
      () => 'completed',
      (e) => e.name,
    );
  }, url);
}

function abortHeldFetch(page: Page) {
  return page.evaluate(() => {
    const scope = window as unknown as {
      heldController: AbortController;
      heldOutcome: Promise<string>;
    };
    scope.heldController.abort();
    return scope.heldOutcome;
  });
}

async function expectHeld(id: string) {
  await expect.poll(async () => (await counts(id, '/held')).count).toBe(1);
  expect((await counts(id, '/held')).released).toBe(false);
}

test('AC-6: a request dropped during the upstream wait keeps the session', async ({
  context,
  page,
  harnessCase,
}) => {
  const host = 'app.example.test';
  const user = await signIn(page, host);
  const original = await refreshCookie(context, host);

  await expireAccess(context);
  await startHeldFetch(page, `/held?case=${harnessCase}`);
  await expectHeld(harnessCase);
  const rotated = await refreshCookie(context, host);
  expect(rotated).not.toBe(original);
  expect(await abortHeldFetch(page)).toBe('AbortError');
  expect((await counts(harnessCase, '/held')).released).toBe(false);

  await page.waitForTimeout(settleMs);
  await expireAccess(context);
  const response = await page.goto(`https://${host}/`);
  expect(response?.status()).toBe(200);
  expect(page.url()).toBe(`https://${host}/`);
  expect(await refreshCookie(context, host)).not.toBe(rotated);
  expect(await reuseAlarms(user)).toBe(0);
});

test('control: without the redirect the same drop ends the session', async ({
  context,
  page,
  harnessCase,
}) => {
  const host = 'legacy.example.test';
  const user = await signIn(page, host);
  const original = await refreshCookie(context, host);

  await expireAccess(context);
  await startHeldFetch(page, `/held?case=${harnessCase}`);
  await expectHeld(harnessCase);
  expect(await refreshCookie(context, host)).toBe(original);
  expect(await abortHeldFetch(page)).toBe('AbortError');

  await page.waitForTimeout(settleMs);
  await expireAccess(context);
  await page.goto(`https://${host}/`);
  expect(new URL(page.url()).pathname).toBe('/_nagare/login');
  await expect.poll(() => reuseAlarms(user)).toBe(1);
});

test('a fetch with redirect error loses the request but not the session', async ({
  context,
  page,
  harnessCase,
}) => {
  const host = 'app.example.test';
  const user = await signIn(page, host);
  const original = await refreshCookie(context, host);

  await expireAccess(context);
  const result = await page.evaluate(
    (url) =>
      fetch(url, { redirect: 'error' }).then(
        () => 'completed',
        (e) => e.name,
      ),
    `/plain?case=${harnessCase}`,
  );
  expect(result).toBe('TypeError');
  expect(await refreshCookie(context, host)).not.toBe(original);
  expect((await counts(harnessCase, '/plain')).count).toBe(0);

  const response = await page.goto(`https://${host}/`);
  expect(response?.status()).toBe(200);
  expect(await reuseAlarms(user)).toBe(0);
});

test('a cross-origin credentialed fetch is forwarded with the cookies', async ({
  context,
  page,
  harnessCase,
}) => {
  const host = 'app.example.test';
  await signIn(page, host);
  const original = await refreshCookie(context, host);

  await expireAccess(context);
  const status = await page.evaluate(
    (url) => fetch(url, { credentials: 'include' }).then((r) => r.status),
    `https://other.example.test/plain?case=${harnessCase}`,
  );
  expect(status).toBe(200);
  expect(await refreshCookie(context, host)).not.toBe(original);
  expect((await counts(harnessCase, '/plain')).count).toBe(1);
});

test('a same-origin EventSource receives its event across the rotation', async ({
  context,
  page,
  harnessCase,
}) => {
  const host = 'app.example.test';
  await signIn(page, host);
  const original = await refreshCookie(context, host);

  await expireAccess(context);
  const message = await page.evaluate(
    (url) =>
      new Promise<string>((resolve, reject) => {
        const source = new EventSource(url);
        (window as unknown as Record<string, unknown>).heldSource = source;
        source.onmessage = (event) => resolve(event.data);
        source.onerror = () => reject(new Error(`readyState ${source.readyState}`));
      }),
    `/sse?case=${harnessCase}`,
  );
  try {
    expect(message).toBe('ready');
    expect(await refreshCookie(context, host)).not.toBe(original);
    expect((await counts(harnessCase, '/sse')).count).toBe(1);
  } finally {
    await page.evaluate(() =>
      ((window as unknown as Record<string, EventSource>).heldSource).close(),
    );
  }
});

test('harness cases do not share counters or barriers', async ({ harnessCase }) => {
  const other = await newCase();
  try {
    await fetch(`${upstream}/plain?case=${harnessCase}`);
    expect((await counts(harnessCase, '/plain')).count).toBe(1);
    expect((await counts(other, '/plain')).count).toBe(0);

    const first = fetch(`${upstream}/held?case=${harnessCase}`);
    const second = fetch(`${upstream}/held?case=${other}`);
    await expect.poll(async () => (await counts(harnessCase, '/held')).count).toBe(1);
    await expect.poll(async () => (await counts(other, '/held')).count).toBe(1);

    await release(harnessCase);
    expect((await first).status).toBe(200);
    expect((await counts(other, '/held')).released).toBe(false);

    await deleteCase(other);
    expect((await second).status).toBe(200);
    expect((await counts(harnessCase, '/held')).released).toBe(true);
    await expect(counts(other, '/held')).rejects.toThrow('404');
  } finally {
    await deleteCase(other);
  }
});
