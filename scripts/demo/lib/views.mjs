// The report views over the trade and CRM tables. "Today" is the dataset's anchor (demo_anchor),
// never current_date: a report must read the same on the day of the capture and a year later,
// and kpi.mjs recomputes every view in JS so verify can reconcile view against rows.
// String ordering anywhere a verifier compares uses COLLATE "C" (code-point order, as JS sorts).

const INVOICED_LINES = `trade_order_lines l
  JOIN trade_invoices i ON i.order_id = l.order_id
  JOIN trade_products p ON p.id = l.product_id`;

export function viewStatements(anchor) {
  return [
    ['demo_anchor', `SELECT DATE '${anchor}' AS anchor_on`],
    ['report_revenue_by_month', `SELECT to_char(issued_on, 'YYYY-MM') AS month, count(*) AS invoices,
  sum(net_eur) AS net_eur, sum(vat_eur) AS vat_eur, sum(total_eur) AS total_eur
FROM trade_invoices GROUP BY 1 ORDER BY 1`],
    ['report_margin_by_category', `SELECT p.category, sum(l.line_net_eur) AS revenue_eur,
  sum(l.quantity * l.unit_cost_eur) AS cost_eur,
  sum(l.line_net_eur) - sum(l.quantity * l.unit_cost_eur) AS margin_eur,
  round(100 * (sum(l.line_net_eur) - sum(l.quantity * l.unit_cost_eur)) / sum(l.line_net_eur), 1) AS margin_pct
FROM ${INVOICED_LINES} GROUP BY p.category ORDER BY p.category`],
    ['report_top_clients', `SELECT rank() OVER (ORDER BY sum(i.net_eur) DESC) AS rank, c.name, count(*) AS invoices,
  sum(i.net_eur) AS revenue_eur
FROM trade_invoices i JOIN companies c ON c.id = i.company_id, demo_anchor a
WHERE i.issued_on > a.anchor_on - 365
GROUP BY c.name ORDER BY rank, c.name COLLATE "C"`],
    ['report_late_invoices', `SELECT i.invoice_no, c.name, i.issued_on, i.due_on, a.anchor_on - i.due_on AS days_late, i.total_eur
FROM trade_invoices i JOIN companies c ON c.id = i.company_id, demo_anchor a
WHERE i.paid_on IS NULL AND i.due_on < a.anchor_on
ORDER BY days_late DESC, i.invoice_no`],
    ['report_stock_levels', `SELECT p.id AS product_id, p.sku, p.name, p.category, coalesce(sum(m.quantity), 0) AS on_hand,
  p.reorder_point, p.reorder_qty
FROM trade_products p LEFT JOIN trade_stock_movements m ON m.product_id = p.id
WHERE p.stocked GROUP BY p.id ORDER BY p.sku`],
    ['report_stock_below_reorder', `SELECT sku, name, category, on_hand, reorder_point, reorder_point - on_hand AS shortfall
FROM report_stock_levels WHERE on_hand < reorder_point ORDER BY sku`],
    ['report_pipeline_by_stage', `SELECT stage, count(*) AS deals, sum(amount_eur) AS amount_eur,
  round(sum(amount_eur * probability_pct / 100), 2) AS weighted_eur
FROM deals GROUP BY stage ORDER BY stage`],
    ['report_orders_by_department_channel', `SELECT o.department, o.channel, count(DISTINCT o.id) AS orders,
  sum(l.line_net_eur) AS net_eur
FROM trade_orders o JOIN trade_order_lines l ON l.order_id = o.id
WHERE o.status <> 'cancelled' GROUP BY o.department, o.channel ORDER BY o.department, o.channel`],
    ['report_expenses_by_month_category', `SELECT to_char(spent_on, 'YYYY-MM') AS month, category, count(*) AS expenses,
  sum(amount_eur) AS amount_eur
FROM trade_expenses GROUP BY 1, 2 ORDER BY 1, 2`],
    ['report_client_lifetime_value', `WITH placed AS (
  SELECT company_id, min(ordered_on) AS first_order_on, max(ordered_on) AS last_order_on, count(*) AS orders
  FROM trade_orders WHERE status <> 'cancelled' GROUP BY company_id
), invoiced AS (
  SELECT company_id, sum(net_eur) AS net_eur FROM trade_invoices GROUP BY company_id
), earned AS (
  SELECT i.company_id, sum(l.line_net_eur - l.quantity * l.unit_cost_eur) AS margin_eur
  FROM trade_order_lines l JOIN trade_invoices i ON i.order_id = l.order_id GROUP BY i.company_id
)
SELECT c.name, p.first_order_on, p.last_order_on, p.orders,
  coalesce(v.net_eur, 0.00) AS invoiced_net_eur, coalesce(e.margin_eur, 0.00) AS margin_eur
FROM companies c JOIN placed p ON p.company_id = c.id
LEFT JOIN invoiced v ON v.company_id = c.id LEFT JOIN earned e ON e.company_id = c.id
WHERE c.kind = 'client' ORDER BY invoiced_net_eur DESC, c.name COLLATE "C"`],
    ['report_supplier_dependency', `SELECT to_char(m.moved_on, 'YYYY-"Q"Q') AS quarter, p.category, s.name AS supplier,
  sum(m.quantity * m.unit_cost_eur) AS purchase_eur,
  round(100 * sum(m.quantity * m.unit_cost_eur)
    / sum(sum(m.quantity * m.unit_cost_eur)) OVER (PARTITION BY to_char(m.moved_on, 'YYYY-"Q"Q'), p.category), 1) AS share_pct
FROM trade_stock_movements m JOIN trade_products p ON p.id = m.product_id JOIN companies s ON s.id = m.supplier_id
WHERE m.kind = 'receipt' GROUP BY 1, 2, 3 ORDER BY 1, 2, 3`],
  ];
}
