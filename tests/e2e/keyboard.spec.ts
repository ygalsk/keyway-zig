import { test, expect } from "@playwright/test";

test.describe("keyboard shortcuts", () => {
  test("Ctrl+K toggles console drawer", async ({ page }) => {
    await page.goto("/__keyway/dashboard");

    // Open console with Ctrl+K
    await page.keyboard.press("Control+k");
    const drawer = page.locator("#console-drawer");
    // Drawer should be open (40vh or 60vh depending on viewport)
    await expect(drawer).toBeVisible();
    await expect(async () => {
      const h = await drawer.evaluate((el) => el.getBoundingClientRect().height);
      expect(h).toBeGreaterThan(50);
    }).toPass({ timeout: 5000 });

    // Close console with Ctrl+K
    await page.keyboard.press("Control+k");
    await expect(async () => {
      const h = await drawer.evaluate((el) => el.getBoundingClientRect().height);
      expect(h).toBeLessThan(5);
    }).toPass({ timeout: 5000 });
  });

  test("? opens keyboard shortcuts dialog", async ({ page }) => {
    await page.goto("/__keyway/dashboard");

    await page.keyboard.press("?");
    await expect(page.locator("#kw-shortcuts")).toBeVisible();
    await expect(page.locator("#kw-shortcuts")).toContainText("Keyboard Shortcuts");

    // Close by pressing ? again
    await page.keyboard.press("?");
    await expect(page.locator("#kw-shortcuts")).not.toBeVisible();
  });
});
