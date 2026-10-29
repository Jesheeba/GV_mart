import { chromium } from "playwright";

const BASE = "http://localhost:5173";

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1440, height: 900 } });
  const errors = [];
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });

  await page.goto(`${BASE}/login`);
  await page.getByLabel(/email/i).fill(process.env.MASTER_EMAIL);
  await page.getByRole("textbox", { name: /password/i }).fill(process.env.MASTER_PASS);
  await page.getByRole("button", { name: "Sign in", exact: true }).click();
  await page.waitForLoadState("networkidle");

  await page.goto(`${BASE}/admin/masters`);
  await page.waitForLoadState("networkidle");
  const settingsBtn = page.locator("h3").getByText("Settings", { exact: true }).locator("xpath=ancestor::button[1]").first();
  await settingsBtn.click();
  await page.waitForLoadState("networkidle");
  await page.waitForTimeout(1200);

  const gstInput = page.locator('input[name="gst_rate"]');
  const gstBefore = await gstInput.inputValue();
  const gstNew = String(Number(gstBefore) === 18 ? 19 : 18);
  await gstInput.fill(gstNew);
  await gstInput.dispatchEvent("blur");

  const gstCard = gstInput.locator("xpath=ancestor::div[contains(@class,'gap-4')][1]");
  const gstSaveBtn = gstCard.getByRole("button", { name: /save/i });
  await gstSaveBtn.click();
  await page.waitForTimeout(1500);

  const travelInput = page.locator('input[name="per_km_minutes"]');
  const travelBefore = await travelInput.inputValue();
  const travelNew = String(Number(travelBefore) + 1);
  await travelInput.fill(travelNew);
  await travelInput.dispatchEvent("blur");
  await page.waitForTimeout(300);

  const navLink = page.getByRole("link", { name: /dashboard|home/i }).first();
  await navLink.click();
  await page.waitForTimeout(800);

  const dialogVisible = await page.getByRole("dialog").isVisible().catch(() => false);
  const stillOnMasters = page.url().includes("/admin/masters");

  await page.screenshot({ path: "ui-audit/screenshots/before/_verify-blocker-gst-saved-travel-dirty.png", fullPage: false });

  console.log(JSON.stringify({ gstBefore, gstNew, travelBefore, travelNew, dialogVisible, stillOnMasters, url: page.url(), consoleErrors: errors.slice(0, 5) }, null, 2));

  // revert gst change to avoid leaving test data dirty for next run
  await browser.close();
})();
