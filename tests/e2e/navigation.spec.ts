import { test, expect } from "@playwright/test";

test.describe("dashboard navigation", () => {
  test("loads overview by default with all nav items", async ({ page }) => {
    await page.goto("/__keyway/dashboard");
    await expect(page.locator("#sidebar")).toBeVisible();

    // All nav items present
    for (const label of ["Overview", "Traffic", "Workers", "Routes", "Scripts", "Hooks"]) {
      await expect(page.locator(`#sidebar >> text=${label}`)).toBeVisible();
    }
  });

  test("clicking nav items changes the view", async ({ page }) => {
    await page.goto("/__keyway/dashboard");

    // Navigate to Traffic
    await page.click('[data-nav="/traffic"]');
    await expect(page).toHaveURL(/#\/traffic/);

    // Navigate to Workers
    await page.click('[data-nav="/workers"]');
    await expect(page).toHaveURL(/#\/workers/);

    // Navigate to Routes
    await page.click('[data-nav="/routes"]');
    await expect(page).toHaveURL(/#\/routes/);

    // Navigate to Scripts
    await page.click('[data-nav="/scripts"]');
    await expect(page).toHaveURL(/#\/scripts/);

    // Navigate to Hooks
    await page.click('[data-nav="/hooks"]');
    await expect(page).toHaveURL(/#\/hooks/);

    // Back to Overview
    await page.click('[data-nav="/"]');
    await expect(page).toHaveURL(/#\//);
  });

  test("connection status indicators are visible", async ({ page }) => {
    await page.goto("/__keyway/dashboard");
    await expect(page.locator("#conn-status")).toBeVisible();
  });
});
