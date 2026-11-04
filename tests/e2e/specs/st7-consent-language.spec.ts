import AxeBuilder from "@axe-core/playwright";
import type { Page } from "@playwright/test";
import { expect, test } from "../lib/fixtures";

// ST7 — the consent banner and the language switcher on the built site. No backend: the banner and
// the switcher are local. The English in ENGLISH_ON_PURPOSE is names and data, not copy.
// Caveat: "no English left" means a string with Latin letters and no Arabic letter. A translation
// that mixes one Arabic word into an English sentence passes, and so does a string added to the
// page only after an interaction this file does not perform (the sign-in portal stays English by
// scope: src/lib/site-strings/en.ts).

const CONSENT_KEY = "prismatica-consent-v1";
const BANNER = "Choose your consent preferences";
const ENGLISH_ON_PURPOSE = [
  /^Prismatica$/,
  /^© \d{4} Prismatica$/,
  /^GitHub$/,
  /^LinkedIn$/,
  /^(EN|ES|AR)$/,
  /^English$/,
  /^S\d+ ·$/,
  /^Marc Delorme$/,
  /^M\. Delorme$/,
  /^Delorme, Marc$/,
  /^Marc \(Varenne\)$/,
  /^dev\.pro\.photo@gmail\.com$/,
  /^(Bouchon Gaspard|Le Jardin de Fourvière|Résidence Les Tilleuls|Hôtel Perrache Rive|Cantine Gerland Campus|Hôtel Vaise Gare)( ·)?$/,
];

async function switchLanguage(page: Page, times: number) {
  const switcher = page.getByRole("banner").locator(".site-header__language");
  for (let click = 0; click < times; click += 1) await switcher.click();
}

// Text the visitor reads or hears that has Latin letters and no Arabic.
function latinOnly(page: Page): Promise<string[]> {
  return page.evaluate(() => {
    const found = new Set<string>();
    const note = (text: string) => {
      const trimmed = text.trim();
      if (/[A-Za-z]{2}/.test(trimmed) && !/[؀-ۿ]/.test(trimmed)) found.add(trimmed);
    };
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    while (walker.nextNode()) {
      const parent = walker.currentNode.parentElement;
      if (parent && !parent.closest("script, style, noscript, [hidden], code")) note(walker.currentNode.textContent ?? "");
    }
    for (const element of document.querySelectorAll("[aria-label], img[alt]")) {
      note(element.getAttribute("aria-label") ?? element.getAttribute("alt") ?? "");
    }
    note(document.title);
    return [...found];
  });
}

test.describe("ST7 consent banner", () => {
  test("shows on a first visit, and the page stays usable behind it", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "first-visit");
    await page.goto("/");
    const banner = page.getByRole("region", { name: BANNER });
    await expect(banner).toBeVisible();
    await expect(banner.getByRole("button", { name: /Reject all/ })).toBeVisible();
    await expect(banner.getByRole("button", { name: /Accept all/ })).toBeVisible();
    await expect(page.getByRole("banner").getByRole("link", { name: "Docs" })).toBeVisible();
  });

  for (const [choice, stored] of [["Reject all", false], ["Accept all", true]] as const) {
    test(`${choice} is remembered across a reload`, async ({ page, consoleGuard }) => {
      consoleGuard.watch(page, "remember");
      await page.goto("/");
      await page.getByRole("region", { name: BANNER }).getByRole("button", { name: new RegExp(choice) }).click();
      await expect(page.getByRole("region", { name: BANNER })).toBeHidden();
      const saved = await page.evaluate((key) => JSON.parse(localStorage.getItem(key) ?? "{}"), CONSENT_KEY);
      expect(saved).toMatchObject({ analytics: stored, marketing: stored });
      await page.reload();
      await expect(page.getByRole("heading", { level: 1 })).toBeVisible();
      await expect(page.getByRole("region", { name: BANNER })).toBeHidden();
    });
  }

  test("the footer brings the choice back", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "cookie-settings");
    await page.goto("/");
    await page.getByRole("region", { name: BANNER }).getByRole("button", { name: /Reject all/ }).click();
    await page.getByRole("contentinfo").getByRole("button", { name: "Cookie settings" }).click();
    await expect(page.getByRole("region", { name: BANNER })).toBeVisible();
  });
});

test.describe("ST7 language", () => {
  test("the switcher takes the landing to Spanish and keeps it across a reload", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "spanish");
    await page.goto("/");
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("One workspace for every department.");
    await switchLanguage(page, 1);
    const heading = page.getByRole("heading", { level: 1 });
    await expect(heading).toHaveText("Un solo espacio de trabajo para todos los departamentos.");
    await expect(page.locator("html")).toHaveAttribute("lang", "es");
    await expect(page.locator("html")).toHaveAttribute("dir", "ltr");
    await expect(page.getByRole("link", { name: "Ver el recorrido de 75 segundos" }).first()).toBeVisible();
    await expect(page.getByRole("region", { name: "Elige tus preferencias de consentimiento" })).toBeVisible();
    await expect(page).toHaveTitle("Prismatica: un solo espacio de trabajo para todos los departamentos");
    await page.reload();
    await expect(heading).toHaveText("Un solo espacio de trabajo para todos los departamentos.");
  });

  test("a second press takes it to Arabic, right to left", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "arabic");
    await page.goto("/");
    await switchLanguage(page, 2);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("مساحة عمل واحدة لكل الأقسام.");
    await expect(page.locator("html")).toHaveAttribute("lang", "ar");
    await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
  });

  test("a third press returns to English, left to right", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "english-again");
    await page.goto("/");
    await switchLanguage(page, 3);
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("One workspace for every department.");
    await expect(page.locator("html")).toHaveAttribute("dir", "ltr");
  });

  test("?lang=ar is right to left before the first paint", async ({ page }) => {
    await page.addInitScript(() => {
      new MutationObserver((_records, observer) => {
        if (document.body) {
          document.documentElement.dataset.dirAtBody = document.documentElement.dir;
          observer.disconnect();
        }
      }).observe(document, { childList: true, subtree: true });
    });
    await page.goto("/?lang=ar");
    await expect(page.locator("html")).toHaveAttribute("data-dir-at-body", "rtl");
  });

  test("the language follows the visitor to the tour page", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "tour");
    await page.goto("/tour/?lang=es");
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("Una semana en Arlet, en 75 segundos");
    await expect(page.getByRole("list", { name: "Capítulos" })).toBeVisible();
    await expect(page.getByText("Lunes", { exact: true })).toBeVisible();
  });

  for (const path of ["/?lang=ar", "/tour/?lang=ar"]) {
    test(`${path} leaves no copy in English`, async ({ page }) => {
      await page.goto(path);
      await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
      await expect(page.locator("[data-lang-label]").first()).toHaveText("اللغة: العربية");
      const left = (await latinOnly(page)).filter((text) => !ENGLISH_ON_PURPOSE.some((name) => name.test(text)));
      expect(left).toEqual([]);
    });
  }

  for (const colorScheme of ["light", "dark"] as const) {
    test(`Arabic holds its layout and passes axe (${colorScheme})`, async ({ browser, baseURL }) => {
      for (const path of ["/?lang=ar", "/tour/?lang=ar"]) {
        for (const width of [390, 768, 1440]) {
          const context = await browser.newContext({ viewport: { width, height: 900 }, colorScheme });
          const page = await context.newPage();
          await page.goto(new URL(path, baseURL).href, { waitUntil: "load" });
          await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
          await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => undefined);
          const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
          expect(overflow, `${path} scrolls sideways at ${width}px`).toBeLessThanOrEqual(0);
          const axe = await new AxeBuilder({ page }).withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa", "wcag22aa"]).analyze();
          const severe = axe.violations.filter((v) => v.impact === "serious" || v.impact === "critical").map((v) => `${v.id} ×${v.nodes.length}`);
          expect(severe, `${path} axe at ${width}px`).toEqual([]);
          await context.close();
        }
      }
    });
  }
});

test.describe("ST7 phone and right-to-left layout", () => {
  test.use({ viewport: { width: 390, height: 844 } });

  for (const [path, signIn] of [["/", "Sign in"], ["/?lang=es", "Iniciar sesión"], ["/?lang=ar", "تسجيل الدخول"]] as const) {
    test(`${path} keeps the phone header on one line`, async ({ page }) => {
      await page.goto(path);
      const button = page.getByRole("banner").getByRole("button", { name: signIn });
      await expect(button).toBeVisible();
      expect((await button.boundingBox())?.height).toBeLessThanOrEqual(44);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
      expect(overflow, "sideways scroll").toBeLessThanOrEqual(0);
    });
  }

  test("a phone changes language from the menu", async ({ page, consoleGuard }) => {
    consoleGuard.watch(page, "phone-language");
    await page.goto("/");
    await expect(page.getByRole("banner").locator(".site-header__language")).toBeHidden();
    await page.getByRole("banner").locator("summary").click();
    await page.getByRole("banner").locator(".site-menu__panel .lang-switcher").click();
    await expect(page.getByRole("heading", { level: 1 })).toHaveText("Un solo espacio de trabajo para todos los departamentos.");
    await expect(page.getByRole("banner").locator(".site-menu__panel")).toBeHidden();
  });

  test("the banner leaves the phone's first screen readable", async ({ page }) => {
    await page.goto("/");
    const box = await page.getByRole("region", { name: BANNER }).boundingBox();
    expect(box?.height).toBeLessThanOrEqual(844 * 0.4);
  });

  test("on a landscape phone the expanded preferences still reach Save", async ({ page }) => {
    await page.setViewportSize({ width: 640, height: 360 });
    await page.goto("/");
    await page.getByRole("button", { name: /Manage preferences/ }).click();
    const save = page.getByRole("button", { name: "Save consent preferences" });
    await save.scrollIntoViewIfNeeded();
    await expect(save).toBeInViewport({ ratio: 1 });
  });

  test("arrows and the convergence read right to left", async ({ page }) => {
    await page.goto("/?lang=ar");
    await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
    await expect(page.locator(".hero .text-link")).toHaveText("أنشئ مساحة عمل");
    const arrow = await page.locator(".hero .text-link").evaluate((link) => getComputedStyle(link, "::after").content);
    expect(arrow).toBe('"←"');
    const flip = await page.locator(".convergence").evaluate((drawing) => getComputedStyle(drawing).transform);
    expect(flip).toMatch(/^matrix\(-1,/);
  });

  test("Arabic labels drop the tracking and the monospace gaps", async ({ page }) => {
    await page.goto("/?lang=ar");
    await expect(page.locator("html")).toHaveAttribute("dir", "rtl");
    const label = await page.locator(".site-footer .label").first().evaluate((element) => {
      const style = getComputedStyle(element);
      return { letterSpacing: style.letterSpacing, family: style.fontFamily };
    });
    expect(label.letterSpacing).toBe("normal");
    expect(label.family).not.toContain("monospace");
  });
});
