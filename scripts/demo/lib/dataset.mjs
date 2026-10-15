// Builds the whole Arlet demo in memory from (anchor, seed, uid8). Pure: the same arguments give
// the same dataset, and every writer renders from it without drawing randomness of its own.
import { parseDay } from './prng.mjs';
import { buildCrm } from './crm.mjs';
import { buildTrade } from './trade.mjs';
import { simulateStock } from './stock.mjs';
import { buildExpenses } from './expenses.mjs';
import { buildInteractions } from './activity.mjs';
import { buildLibrary } from './library.mjs';
import { buildPages } from './pages.mjs';
import { storyDates, storyFacts } from './story.mjs';

export function validateArgs({ anchor, seed, uid8 }) {
  const errors = [];
  if (typeof anchor !== 'string' || parseDay(anchor) === null) errors.push(`--anchor must be a real YYYY-MM-DD date (got ${anchor})`);
  if (!Number.isSafeInteger(seed)) errors.push(`--seed must be an integer (got ${seed})`);
  if (typeof uid8 !== 'string' || !/^[0-9a-f]{8}$/.test(uid8)) errors.push(`--uid8 must be 8 lowercase hex digits (got ${uid8})`);
  return errors;
}

export function buildDataset({ anchor, seed, uid8 }) {
  const errors = validateArgs({ anchor, seed, uid8 });
  if (errors.length > 0) throw new Error(errors.join('; '));
  const args = { anchor, seed, uid8 };
  const story = storyDates(anchor);
  const crm = buildCrm(args);
  const trade = buildTrade(args, crm.idx, story);
  const moves = simulateStock(args, trade, story);
  const tables = {
    ...crm.rows, trade_products: trade.products, trade_orders: trade.orders, trade_order_lines: trade.lines,
    trade_invoices: trade.invoices, trade_stock_movements: moves, trade_expenses: buildExpenses(args, crm.idx, trade.start),
  };
  const interactions = buildInteractions(args, crm.idx, trade.products, story);
  const library = buildLibrary(args, crm.idx);
  const facts = storyFacts({ anchor, story, trade, moves, tables });
  const { pages } = buildPages(args, crm.idx, library, story, facts);
  return { args, spike: false, story, facts, tables, interactions, library, pages };
}
