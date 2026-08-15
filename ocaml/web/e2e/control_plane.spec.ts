import { expect, test } from "@playwright/test";

const baseURL = process.env.NIXPLOY_E2E_URL ?? "http://127.0.0.1:8080";

for (const viewport of [
  { name: "mobile", width: 390, height: 844 },
  { name: "desktop", width: 1440, height: 1100 },
]) {
  test(`${viewport.name} operator workflows`, async ({ page }) => {
    await page.setViewportSize(viewport);
    await page.goto(baseURL);

    await expect(page.getByText("CONNECTED", { exact: true })).toBeVisible();
    await expect(page.getByText("Health and capacity")).toBeVisible();
    await expect(page.locator(".target-metrics")).toBeVisible({ timeout: 60_000 });

    const horizontalOverflow = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
    );
    expect(horizontalOverflow).toBe(false);

    for (const control of await page.locator("button:visible").all()) {
      const box = await control.boundingBox();
      expect(box?.height ?? 0).toBeGreaterThanOrEqual(44);
    }

    const application = page.locator(".application-card").first();
    await application.getByRole("button", { name: "PRUNE RESOURCES" }).click();
    const pruneConfirmation = application.getByLabel(/Confirm resource prune for/);
    await expect(pruneConfirmation).toBeVisible();
    await expect(
      pruneConfirmation.getByText(/removes owned containers, scoped secrets, and the Caddy route/i),
    ).toBeVisible();
    await expect(pruneConfirmation.getByText(/causes downtime/i)).toBeVisible();
    await expect(
      pruneConfirmation.getByRole("button", { name: "CONFIRM PRUNE" }),
    ).toBeVisible();
    await pruneConfirmation.getByRole("button", { name: "KEEP RESOURCES" }).click();
    await expect(pruneConfirmation).toBeHidden();

    await application.getByRole("button", { name: "PREVIEW MAIN" }).click();
    const confirmation = application.getByLabel("Confirm deployment commit");
    await expect(confirmation).toBeVisible({
      timeout: 30_000,
    });
    await expect(confirmation.getByRole("button", { name: "DEPLOY THIS COMMIT" })).toBeVisible();
    await confirmation.getByRole("button", { name: "CANCEL" }).click();

    await application.getByRole("button", { name: "VIEW LOGS" }).click();
    const logLines = page.locator(".log-line code");
    await expect(logLines.first()).toBeVisible({ timeout: 60_000 });
    const firstLine = (await logLines.first().textContent())?.trim() ?? "";
    expect(firstLine.length).toBeGreaterThan(0);

    const query = firstLine.slice(0, Math.min(8, firstLine.length));
    await page.getByRole("searchbox", { name: "SEARCH LOGS" }).fill(query);
    await expect(page.locator(".log-line mark").first()).toBeVisible();
    await page.getByRole("button", { name: "PAUSE" }).click();
    await expect(page.getByText("PAUSED", { exact: true })).toBeVisible();
    await page.getByRole("button", { name: "RESUME" }).click();
    await expect(page.getByText("FOLLOWING", { exact: true })).toBeVisible();

    const finalOverflow = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
    );
    expect(finalOverflow).toBe(false);
  });
}
