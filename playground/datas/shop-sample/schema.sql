-- Canonical schema for the shop-sample dataset.
-- Written in portable SQL (PostgreSQL dialect); the loaders in ../loaders/ adapt
-- it per engine (e.g. SERIAL/IDENTITY, AUTO_INCREMENT, DATETIME2, ENUM, etc.).
-- Load order matters: customers + products before orders (foreign keys).

CREATE TABLE customers (
  id          INTEGER     PRIMARY KEY,
  name        TEXT        NOT NULL,
  email       TEXT        NOT NULL UNIQUE,
  created_at  DATE        NOT NULL
);

CREATE TABLE products (
  id          INTEGER     PRIMARY KEY,
  name        TEXT        NOT NULL,
  price_cents INTEGER     NOT NULL CHECK (price_cents >= 0),
  stock       INTEGER     NOT NULL DEFAULT 0
);

CREATE TABLE orders (
  id          INTEGER     PRIMARY KEY,
  customer_id INTEGER     NOT NULL REFERENCES customers(id),
  product_id  INTEGER     NOT NULL REFERENCES products(id),
  qty         INTEGER     NOT NULL CHECK (qty > 0),
  status      TEXT        NOT NULL CHECK (status IN ('pending','paid','shipped','cancelled')),
  created_at  DATE        NOT NULL
);

-- Suggested indexes to practice with (see wiki/database-cli/*/03-indexes.md):
--   CREATE INDEX idx_orders_customer ON orders(customer_id);
--   CREATE INDEX idx_orders_status   ON orders(status);
