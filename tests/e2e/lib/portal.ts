import type { Page } from "@playwright/test";
import { PRISMATICA_URL } from "./env";

/** Landing → portal in the given mode ("Create account" or "Sign in"). */
export async function openPortal(page: Page, mode: "Create account" | "Sign in") {
  await page.goto(PRISMATICA_URL);
  await page.getByRole("banner").getByRole("button", { name: "Sign in", exact: true }).click();
  const portal = page.getByRole("dialog", { name: "Prismatica workspace portal" });
  await portal.getByRole("group", { name: "Authentication mode" }).getByRole("button", { name: mode, exact: true }).click();
  return portal;
}
