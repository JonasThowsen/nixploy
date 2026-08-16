import { expect, request, test } from "@playwright/test";

const baseURL = (process.env.NIXPLOY_E2E_URL ?? "http://127.0.0.1:8080").replace(/\/$/, "");

async function firstApplicationKey(page: import("@playwright/test").Page) {
  await page.goto(`${baseURL}/apps`);
  await expect(page.getByRole("heading", { name: "Recognized applications" })).toBeVisible();
  const item = page.locator(".application-item").first();
  await expect(item).toBeVisible({ timeout: 60_000 });
  return (await item.locator("h3").textContent())?.trim() ?? "";
}

async function expectNoOverflow(page: import("@playwright/test").Page) {
  expect(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= document.documentElement.clientWidth,
    ),
  ).toBe(true);
}

async function expectControlTargets(page: import("@playwright/test").Page) {
  for (const control of await page.locator("button:visible, a:visible, input:visible").all()) {
    const box = await control.boundingBox();
    expect(box?.width ?? 0).toBeGreaterThanOrEqual(44);
    expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
  }
}

test("authorized shell routes, health, assets, and genuine 404s", async () => {
  const client = await request.newContext();
  for (const path of ["/", "/apps", "/telemetry", "/apps/nonexistent"]) {
    const response = await client.get(`${baseURL}${path}`);
    expect(response.status()).toBe(200);
    expect(await response.text()).toContain('<div id="app"></div>');
  }
  expect((await client.get(`${baseURL}/healthz`)).status()).toBe(200);
  expect(await (await client.get(`${baseURL}/healthz`)).text()).toBe("ok\n");
  expect((await client.get(`${baseURL}/main.js`)).status()).toBe(200);
  expect((await client.get(`${baseURL}/app.css`)).status()).toBe(200);
  expect((await client.get(`${baseURL}/arbitrary-unknown-path`)).status()).toBe(404);
  expect((await client.get(`${baseURL}/missing.js`)).status()).toBe(404);

  const invalidIdentityHeaders = {
    "Tailscale-User-Login": "not-the-configured-operator@example.invalid",
  };
  const root = await client.get(`${baseURL}/`, { headers: invalidIdentityHeaders });
  const deep = await client.get(`${baseURL}/telemetry`, { headers: invalidIdentityHeaders });
  expect(deep.status()).toBe(root.status());
  await client.dispose();
});

test("direct routes and reload retain the selected application", async ({ page }) => {
  await page.goto(`${baseURL}/`);
  await expect(page.getByRole("heading", { name: "What needs attention now" })).toBeVisible();
  await expect(
    page.getByRole("heading", { name: "Host and application health" }),
  ).toBeVisible();
  await expect(page.locator(".telemetry-summary .target-summary-list")).toHaveCount(0);
  await page.getByRole("link", { name: "Open telemetry" }).click();
  await expect(page).toHaveURL(`${baseURL}/telemetry`);
  await expect(
    page.getByRole("heading", { name: "Machine and application telemetry" }),
  ).toBeVisible();
  await page.goto(`${baseURL}/apps`);
  await expect(page.getByRole("heading", { name: "Recognized applications" })).toBeVisible();
  await page.goto(`${baseURL}/telemetry`);
  await expect(page.getByRole("heading", { name: "Machine and application telemetry" })).toBeVisible();

  const key = await firstApplicationKey(page);
  await page.goto(`${baseURL}/apps/${key}`);
  await expect(page.locator("#page-heading")).toHaveText(key);
  await expect(page).toHaveTitle(`${key} · nixploy`);
  await expect(page.locator(".application-hero h2")).toHaveText(key);
  await page.reload();
  await expect(page).toHaveURL(`${baseURL}/apps/${key}`);
  await expect(page.locator("#page-heading")).toHaveText(key);
  await expect(page.locator(".application-hero h2")).toHaveText(key, { timeout: 60_000 });
});

test("SPA navigation, Back, and Forward synchronize URL, navigation, and headings", async ({ page }) => {
  const key = await firstApplicationKey(page);
  await page.goto(`${baseURL}/`);
  await page.evaluate(() => ((window as typeof window & { __nixployProbe?: string }).__nixployProbe = "alive"));

  await page.getByRole("link", { name: "Applications", exact: true }).first().click();
  await expect(page).toHaveURL(`${baseURL}/apps`);
  await expect(page.locator("#page-heading")).toHaveText("Applications");

  await page.locator(".application-item").filter({ hasText: key }).first().click();
  await expect(page).toHaveURL(`${baseURL}/apps/${key}`);
  await expect(page.locator("#page-heading")).toHaveText(key);

  await page.getByRole("link", { name: "Telemetry", exact: true }).click();
  await expect(page).toHaveURL(`${baseURL}/telemetry`);
  await expect(page.locator("#page-heading")).toHaveText("Telemetry");
  await expect(page).toHaveTitle("Telemetry · nixploy");
  expect(await page.evaluate(() => (window as typeof window & { __nixployProbe?: string }).__nixployProbe)).toBe("alive");

  await page.goBack();
  await expect(page).toHaveURL(`${baseURL}/apps/${key}`);
  await expect(page.locator("#page-heading")).toHaveText(key);
  await expect(page).toHaveTitle(`${key} · nixploy`);
  await expect(page.locator(`.rail-app[aria-current="page"]`)).toContainText(key);

  await page.goBack();
  await expect(page).toHaveURL(`${baseURL}/apps`);
  await expect(page.locator("#page-heading")).toHaveText("Applications");
  await expect(page.locator('.nav-link[aria-current="page"]')).toContainText("Applications");

  await page.goForward();
  await expect(page).toHaveURL(`${baseURL}/apps/${key}`);
  await expect(page.locator("#page-heading")).toHaveText(key);
});

test("unknown application remains selected and trailing slashes canonicalize with replaceState", async ({ page }) => {
  const unknown = "definitely-not-a-recognized-application";
  await page.goto(`${baseURL}/apps/${unknown}`);
  await expect(page).toHaveURL(`${baseURL}/apps/${unknown}`);
  await expect(page.getByText("Application not found", { exact: true })).toBeVisible({ timeout: 60_000 });
  await expect(page.locator("#page-heading")).toHaveText(unknown);

  await page.goto(`${baseURL}/apps`);
  const historyLength = await page.evaluate(() => {
    history.pushState(null, "", "/apps/");
    const length = history.length;
    window.dispatchEvent(new PopStateEvent("popstate"));
    return length;
  });
  await expect(page).toHaveURL(`${baseURL}/apps`);
  expect(await page.evaluate(() => history.length)).toBe(historyLength);
  await expect(page.locator("#page-heading")).toHaveText("Applications");
});

for (const viewport of [
  { name: "mobile", width: 390, height: 844 },
  { name: "desktop", width: 1440, height: 1100 },
]) {
  test(`${viewport.name} non-destructive operator workflows and layout`, async ({ page }) => {
    await page.setViewportSize(viewport);
    const key = await firstApplicationKey(page);
    await page.goto(`${baseURL}/apps/${key}`);
    await expect(page.getByText(/Connected|Connection stale/)).toBeVisible();
    await expect(page.locator(".application-hero")).toBeVisible({ timeout: 60_000 });
    await expectNoOverflow(page);
    await expectControlTargets(page);

    await page.getByRole("button", { name: "Prune resources" }).click();
    const pruneConfirmation = page.getByRole("alertdialog", { name: new RegExp(`Application ${key}`, "i") });
    await expect(pruneConfirmation).toBeVisible();
    await expect(pruneConfirmation.getByText(/removes owned containers, scoped secrets, and the Caddy route/i)).toBeVisible();
    await expect(pruneConfirmation.getByText(/causes downtime/i)).toBeVisible();
    const keepResources = pruneConfirmation.getByRole("button", { name: "Keep resources" });
    await expect(keepResources).toBeFocused();
    expect(
      await keepResources.evaluate(
        (keep) => keep.nextElementSibling?.textContent?.trim() === "Confirm prune",
      ),
    ).toBe(true);
    await expectNoOverflow(page);
    await keepResources.click();
    await expect(pruneConfirmation).toBeHidden();
    await expect(page.getByRole("button", { name: "Prune resources" })).toBeFocused();

    await page.getByRole("button", { name: "Preview main" }).click();
    const confirmation = page.getByLabel("Confirm deployment commit");
    await expect(confirmation).toBeVisible({ timeout: 30_000 });
    await expect(confirmation.getByRole("button", { name: "Deploy this commit" })).toBeVisible();
    await confirmation.getByRole("button", { name: "Cancel" }).click();
    await expect(confirmation).toBeHidden();
    await expect(page.getByRole("button", { name: "Preview main" })).toBeFocused();

    const logLines = page.locator(".log-line code");
    await expect(logLines.first()).toBeVisible({ timeout: 60_000 });
    const firstLine = (await logLines.first().textContent())?.trim() ?? "";
    expect(firstLine.length).toBeGreaterThan(0);
    const query = firstLine.slice(0, Math.min(8, firstLine.length));
    await page.getByRole("searchbox", { name: "Search logs" }).fill(query);
    await expect(page.locator(".log-line mark").first()).toBeVisible();
    await page.getByRole("button", { name: "Pause" }).click();
    await expect(page.getByText("Paused", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "Resume" }).click();
    await expect(page.getByText("Following", { exact: true })).toBeVisible();

    if (viewport.name === "mobile") {
      const menu = page.getByRole("button", { name: "Open navigation" });
      await menu.click();
      await expect(page.locator("#primary-navigation")).toBeFocused();
      await page.keyboard.press("Escape");
      await expect(page.getByRole("button", { name: "Open navigation" })).toBeFocused();
    }

    await expectNoOverflow(page);
    await expectControlTargets(page);
  });
}
