// The CRM mount's tables, declared once: the DDL, the INSERT column lists and the in-memory
// foreign-key check all read this list, so they cannot disagree. Order is FK dependency order.
// Every table lives in `public` because mount introspection reads only `public` (PLAN §5.4).
// No column defaults to now(): a re-run must leave every row byte-identical (row checksum).

const DEPARTMENTS = "'sales','warehouse','finance','service','management'";

function col(name, type, opts = {}) {
  return { name, type, null: Boolean(opts.null), fk: opts.fk || null, unique: Boolean(opts.unique) };
}

export const TABLES = [
  {
    name: 'companies',
    columns: [
      col('id', 'uuid'), col('name', 'text', { unique: true }), col('kind', 'text'),
      col('segment', 'text'), col('city', 'text'), col('postcode', 'text'),
      col('email_domain', 'text'), col('payment_terms_days', 'integer'),
      col('credit_limit_eur', 'numeric(12,2)'), col('relationship_since', 'date'),
    ],
    checks: [
      "kind IN ('self','client','supplier','partner')",
      "payment_terms_days IN (0,30,45,60)",
      'credit_limit_eur >= 0',
      "email_domain ~ '^[a-z0-9-]+\\.example\\.com$'",
    ],
  },
  {
    name: 'contacts',
    columns: [
      col('id', 'uuid'), col('company_id', 'uuid', { fk: 'companies' }), col('first_name', 'text'),
      col('last_name', 'text'), col('email', 'text', { unique: true }), col('phone', 'text'),
      col('job_title', 'text'), col('department', 'text', { null: true }), col('created_on', 'date'),
    ],
    checks: [
      "email ~ '^[a-z0-9._-]+@[a-z0-9-]+\\.example\\.com$'",
      // [+] rather than \+: the same regex, and the schema text no longer looks like a phone number.
      "phone ~ '^[+]33 6 39 98 [0-9]{2} [0-9]{2}$'",
      `department IS NULL OR department IN (${DEPARTMENTS})`,
    ],
  },
  {
    name: 'company_contacts',
    columns: [
      col('id', 'uuid'), col('company_id', 'uuid', { fk: 'companies' }),
      col('contact_id', 'uuid', { fk: 'contacts' }), col('role', 'text'), col('since_on', 'date'),
    ],
    checks: [
      "role IN ('buyer','head_chef','general_manager','accounts_payable','technical_contact'," +
        "'sales_rep','logistics','accounts_receivable','technical_support','account_manager'," +
        "'staff','arlet_account_manager','arlet_technician','arlet_buyer')",
    ],
    uniques: [['company_id', 'contact_id', 'role']],
  },
  {
    name: 'deals',
    columns: [
      col('id', 'uuid'), col('company_id', 'uuid', { fk: 'companies' }),
      col('owner_contact_id', 'uuid', { fk: 'contacts' }), col('title', 'text'), col('stage', 'text'),
      col('amount_eur', 'numeric(12,2)'), col('probability_pct', 'integer'), col('opened_on', 'date'),
      col('expected_close_on', 'date'), col('closed_on', 'date', { null: true }),
    ],
    checks: [
      "stage IN ('lead','qualified','proposal','negotiation','won','lost')",
      'probability_pct BETWEEN 0 AND 100', 'amount_eur > 0',
      'expected_close_on >= opened_on',
      "(stage IN ('won','lost')) = (closed_on IS NOT NULL)",
      'closed_on IS NULL OR closed_on >= opened_on',
    ],
  },
  {
    name: 'deal_contacts',
    columns: [
      col('id', 'uuid'), col('deal_id', 'uuid', { fk: 'deals' }),
      col('contact_id', 'uuid', { fk: 'contacts' }), col('role', 'text'),
    ],
    checks: ["role IN ('decision_maker','influencer','champion','technical','finance')"],
    uniques: [['deal_id', 'contact_id']],
  },
  {
    name: 'trade_products',
    columns: [
      col('id', 'uuid'), col('sku', 'text', { unique: true }), col('name', 'text'), col('category', 'text'),
      col('supplier_id', 'uuid', { fk: 'companies' }),
      col('second_supplier_id', 'uuid', { fk: 'companies', null: true }),
      col('unit_cost_eur', 'numeric(10,2)'), col('unit_price_eur', 'numeric(10,2)'),
      col('stocked', 'boolean'), col('reorder_point', 'integer'), col('reorder_qty', 'integer'),
      col('lead_time_days', 'integer'),
    ],
    checks: [
      "category IN ('cooking','refrigeration','dishwashing','preparation','ventilation'," +
        "'stainless_furniture','smallwares','consumables','spare_parts')",
      'unit_cost_eur > 0', 'unit_price_eur > unit_cost_eur', 'reorder_point >= 0',
      'reorder_qty > 0', 'lead_time_days > 0',
      'second_supplier_id IS NULL OR second_supplier_id <> supplier_id',
    ],
  },
  {
    name: 'trade_orders',
    columns: [
      col('id', 'uuid'), col('order_no', 'text', { unique: true }),
      col('company_id', 'uuid', { fk: 'companies' }), col('contact_id', 'uuid', { fk: 'contacts' }),
      col('salesperson_id', 'uuid', { fk: 'contacts' }), col('deal_id', 'uuid', { fk: 'deals', null: true }),
      col('department', 'text'), col('channel', 'text'), col('status', 'text'),
      col('ordered_on', 'date'), col('shipped_on', 'date', { null: true }),
    ],
    checks: [
      "department IN ('sales','service')",
      "channel IN ('field_sales','phone','email','web_portal')",
      "status IN ('open','shipped','cancelled')",
      "(status = 'shipped') = (shipped_on IS NOT NULL)",
      'shipped_on IS NULL OR shipped_on >= ordered_on',
    ],
  },
  {
    name: 'trade_order_lines',
    columns: [
      col('id', 'uuid'), col('order_id', 'uuid', { fk: 'trade_orders' }), col('line_no', 'integer'),
      col('product_id', 'uuid', { fk: 'trade_products' }), col('quantity', 'integer'),
      col('unit_price_eur', 'numeric(10,2)'), col('unit_cost_eur', 'numeric(10,2)'),
      col('discount_pct', 'integer'), col('line_net_eur', 'numeric(12,2)'),
    ],
    checks: [
      'quantity > 0', 'line_no > 0', 'discount_pct BETWEEN 0 AND 30',
      // Proves the generator's integer-cent rounding agrees with PostgreSQL's numeric rounding.
      'line_net_eur = round(quantity * unit_price_eur * (100 - discount_pct) / 100, 2)',
    ],
    uniques: [['order_id', 'line_no']],
  },
  {
    name: 'trade_invoices',
    columns: [
      col('id', 'uuid'), col('invoice_no', 'text', { unique: true }),
      col('order_id', 'uuid', { fk: 'trade_orders', unique: true }),
      col('company_id', 'uuid', { fk: 'companies' }), col('issued_on', 'date'), col('due_on', 'date'),
      col('paid_on', 'date', { null: true }), col('net_eur', 'numeric(12,2)'),
      col('vat_eur', 'numeric(12,2)'), col('total_eur', 'numeric(12,2)'),
    ],
    checks: [
      'due_on >= issued_on', 'paid_on IS NULL OR paid_on >= issued_on',
      'net_eur > 0', 'vat_eur = round(net_eur * 0.20, 2)', 'total_eur = net_eur + vat_eur',
    ],
  },
  {
    name: 'trade_stock_movements',
    columns: [
      col('id', 'uuid'), col('product_id', 'uuid', { fk: 'trade_products' }), col('moved_on', 'date'),
      col('kind', 'text'), col('quantity', 'integer'),
      col('order_line_id', 'uuid', { fk: 'trade_order_lines', null: true }),
      col('supplier_id', 'uuid', { fk: 'companies', null: true }),
      col('unit_cost_eur', 'numeric(10,2)', { null: true }), col('expedited', 'boolean'),
    ],
    checks: [
      "kind IN ('opening','receipt','shipment','return','adjustment')",
      'quantity <> 0',
      "(kind IN ('opening','receipt','return')) <= (quantity > 0)",
      "(kind = 'shipment') <= (quantity < 0)",
      "(kind IN ('shipment','return')) = (order_line_id IS NOT NULL)",
      "(kind = 'receipt') = (supplier_id IS NOT NULL AND unit_cost_eur IS NOT NULL)",
      "NOT expedited OR kind = 'receipt'",
    ],
  },
  {
    name: 'trade_expenses',
    columns: [
      col('id', 'uuid'), col('spent_on', 'date'), col('category', 'text'), col('department', 'text'),
      col('payee_company_id', 'uuid', { fk: 'companies' }),
      col('approved_by_id', 'uuid', { fk: 'contacts' }), col('description', 'text'),
      col('amount_eur', 'numeric(10,2)'),
    ],
    checks: [
      "category IN ('rent','utilities','vehicle_lease','fuel','vehicle_maintenance','insurance','it'," +
        "'marketing','training','travel','freight','professional_fees')",
      `department IN (${DEPARTMENTS})`, 'amount_eur > 0',
    ],
  },
];

export const TABLE_NAMES = TABLES.map((t) => t.name);
