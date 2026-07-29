/* ============================================================
   PROJECT: E-commerce User Behavior & Database Analysis
   Primary DB Engine: PostgreSQL
   (See "CROSS-DATABASE NOTES" at the bottom for MySQL / SQL Server equivalents)
   ============================================================
   Contents:
     1. Schema (customers, products, orders, order_items, payments)
     2. Sample data — all dates generated RELATIVE to CURRENT_DATE,
        so the logic stays correct no matter when you run this script
     3. Main business query: high-value customers (last 6 months)
        who placed no order in the last 1 month
        -> uses CTE, Window Functions (RANK/DENSE_RANK), Subquery,
           AND the payments table (only counts successfully paid orders)
     4. Bonus analytical queries
     5. Cross-database syntax notes (MySQL / SQL Server)
   ============================================================ */


-- ============================================================
-- 1. SCHEMA
-- ============================================================

DROP TABLE IF EXISTS payments;
DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS products;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id     SERIAL PRIMARY KEY,
    full_name       VARCHAR(100) NOT NULL,
    email           VARCHAR(120) UNIQUE NOT NULL,
    city            VARCHAR(60),
    signup_date     DATE NOT NULL
);

CREATE TABLE products (
    product_id      SERIAL PRIMARY KEY,
    product_name    VARCHAR(120) NOT NULL,
    category        VARCHAR(60) NOT NULL,
    price           NUMERIC(10,2) NOT NULL
);

CREATE TABLE orders (
    order_id        SERIAL PRIMARY KEY,
    customer_id     INT NOT NULL REFERENCES customers(customer_id),
    order_date      DATE NOT NULL,
    status          VARCHAR(20) DEFAULT 'completed'  -- completed / cancelled / returned
);

CREATE TABLE order_items (
    order_item_id   SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES orders(order_id),
    product_id      INT NOT NULL REFERENCES products(product_id),
    quantity        INT NOT NULL,
    unit_price      NUMERIC(10,2) NOT NULL   -- price at time of order (may differ from current price)
);

CREATE TABLE payments (
    payment_id      SERIAL PRIMARY KEY,
    order_id        INT NOT NULL REFERENCES orders(order_id),
    payment_date    DATE NOT NULL,
    amount          NUMERIC(10,2) NOT NULL,
    method          VARCHAR(30) NOT NULL,          -- bKash / Card / COD / Nagad
    payment_status  VARCHAR(20) DEFAULT 'success'  -- success / failed / refunded
);


-- ============================================================
-- 2. SAMPLE DATA
--    All order/payment dates are computed as CURRENT_DATE minus
--    an offset, so the "6-month" / "1-month" filters in the
--    queries below always land on meaningful rows — regardless
--    of what today's actual date is when you run this script.
-- ============================================================

INSERT INTO customers (full_name, email, city, signup_date) VALUES
('Rafiq Islam',   'rafiq@example.com',   'Dhaka',      CURRENT_DATE - INTERVAL '18 months'),
('Nusrat Jahan',  'nusrat@example.com',  'Chattogram', CURRENT_DATE - INTERVAL '16 months'),
('Kamal Hossain', 'kamal@example.com',   'Sylhet',     CURRENT_DATE - INTERVAL '20 months'),
('Farzana Akter', 'farzana@example.com','Khulna',      CURRENT_DATE - INTERVAL '14 months'),
('Shahed Ahmed',  'shahed@example.com',  'Dhaka',      CURRENT_DATE - INTERVAL '24 months'),
('Mim Chowdhury', 'mim@example.com',     'Rajshahi',   CURRENT_DATE - INTERVAL '17 months');

INSERT INTO products (product_name, category, price) VALUES
('iPhone 15 Case',        'Accessories', 800.00),
('Samsung 55" TV',        'Electronics', 55000.00),
('Nike Running Shoes',    'Fashion',     4500.00),
('Office Chair',          'Furniture',   7200.00),
('Bluetooth Headphones',  'Electronics', 3200.00),
('Laptop Backpack',       'Accessories', 1500.00),
('Gaming Laptop',         'Electronics', 95000.00),
('Kitchen Blender',       'Home',        2800.00);

-- Orders: dates built from CURRENT_DATE so the scenario stays valid over time
INSERT INTO orders (customer_id, order_date, status) VALUES
(1, CURRENT_DATE - INTERVAL '50 days',  'completed'),  -- Rafiq: within 6mo, NOT within last 1mo
(1, CURRENT_DATE - INTERVAL '5 months', 'completed'),
(2, CURRENT_DATE - INTERVAL '5 days',   'completed'),  -- Nusrat: HAS an order within last 1mo
(2, CURRENT_DATE - INTERVAL '3 months', 'completed'),
(3, CURRENT_DATE - INTERVAL '2 months', 'completed'),  -- Kamal: within 6mo, NOT within last 1mo (big spender)
(3, CURRENT_DATE - INTERVAL '4 months', 'completed'),
(4, CURRENT_DATE - INTERVAL '8 months', 'completed'),  -- Farzana: OUTSIDE the 6-month window entirely
(5, CURRENT_DATE - INTERVAL '35 days',  'completed'),  -- Shahed: within 6mo, NOT within last 1mo
(6, CURRENT_DATE - INTERVAL '15 days',  'cancelled');  -- Mim: only a cancelled order recently

INSERT INTO order_items (order_id, product_id, quantity, unit_price) VALUES
(1, 7, 1, 95000.00),   -- Rafiq bought a Gaming Laptop
(2, 1, 2, 800.00),
(3, 5, 1, 3200.00),
(4, 2, 1, 55000.00),
(5, 7, 1, 95000.00),   -- Kamal also bought a Gaming Laptop
(5, 3, 1, 4500.00),
(6, 6, 2, 1500.00),
(7, 4, 1, 7200.00),
(8, 2, 1, 55000.00),   -- Shahed bought a TV
(9, 8, 1, 2800.00);

-- Payments: dates match their order's date; a couple of failed/refunded rows
-- are included on purpose so the main query can prove it's filtering on payment_status
INSERT INTO payments (order_id, payment_date, amount, method, payment_status) VALUES
(1, CURRENT_DATE - INTERVAL '50 days',  95000.00, 'Card',  'success'),
(2, CURRENT_DATE - INTERVAL '5 months', 1600.00,  'bKash', 'success'),
(3, CURRENT_DATE - INTERVAL '5 days',   3200.00,  'COD',   'success'),
(4, CURRENT_DATE - INTERVAL '3 months', 55000.00, 'Card',  'success'),
(5, CURRENT_DATE - INTERVAL '2 months', 99500.00, 'bKash', 'success'),
(6, CURRENT_DATE - INTERVAL '4 months', 3000.00,  'COD',   'failed'),   -- payment failed -> should NOT count as real spend
(7, CURRENT_DATE - INTERVAL '8 months', 7200.00,  'Card',  'success'),
(8, CURRENT_DATE - INTERVAL '35 days',  55000.00, 'Card',  'success'),
(9, CURRENT_DATE - INTERVAL '15 days',  2800.00,  'bKash', 'refunded'); -- refunded -> should NOT count as real spend


-- ============================================================
-- 3. MAIN BUSINESS QUERY
--    "High-value customers over the last 6 months who placed
--     NO order in the last 1 month."
--    Uses: CTE, Window Functions (RANK/DENSE_RANK), Subquery (NOT EXISTS),
--          AND the payments table — only successfully paid amounts count
--          as real "spend" (failed/refunded payments are excluded).
-- ============================================================

WITH last_6_months_spend AS (
    -- Step 1: total SUCCESSFULLY PAID spend per customer in the last 6 months
    SELECT
        c.customer_id,
        c.full_name,
        SUM(pay.amount) AS total_spent_6mo
    FROM customers c
    JOIN orders o     ON o.customer_id = c.customer_id
    JOIN payments pay ON pay.order_id  = o.order_id
    WHERE o.status = 'completed'
      AND pay.payment_status = 'success'          -- <-- payments table condition
      AND o.order_date >= CURRENT_DATE - INTERVAL '6 months'
    GROUP BY c.customer_id, c.full_name
),
ranked_spenders AS (
    -- Step 2: rank customers by verified spend
    SELECT
        customer_id,
        full_name,
        total_spent_6mo,
        RANK()       OVER (ORDER BY total_spent_6mo DESC) AS spend_rank,
        DENSE_RANK() OVER (ORDER BY total_spent_6mo DESC) AS spend_dense_rank
    FROM last_6_months_spend
)
SELECT
    r.customer_id,
    r.full_name,
    r.total_spent_6mo,
    r.spend_rank
FROM ranked_spenders r
WHERE NOT EXISTS (
    -- Step 3: subquery — exclude anyone who ordered in the last 1 month
    SELECT 1
    FROM orders o2
    WHERE o2.customer_id = r.customer_id
      AND o2.status = 'completed'
      AND o2.order_date >= CURRENT_DATE - INTERVAL '1 month'
)
ORDER BY r.total_spent_6mo DESC;


-- ============================================================
-- 4. BONUS QUERIES
-- ============================================================

-- 4a. Top 3 best-selling products per category (DENSE_RANK + CTE)
WITH product_sales AS (
    SELECT
        p.category,
        p.product_name,
        SUM(oi.quantity) AS units_sold,
        DENSE_RANK() OVER (
            PARTITION BY p.category
            ORDER BY SUM(oi.quantity) DESC
        ) AS category_rank
    FROM products p
    JOIN order_items oi ON oi.product_id = p.product_id
    JOIN orders o        ON o.order_id   = oi.order_id
    WHERE o.status = 'completed'
    GROUP BY p.category, p.product_name
)
SELECT category, product_name, units_sold, category_rank
FROM product_sales
WHERE category_rank <= 3
ORDER BY category, category_rank;


-- 4b. New vs returning customer orders, grouped by month (Window Function: ROW_NUMBER)
WITH customer_order_seq AS (
    SELECT
        customer_id,
        order_id,
        order_date,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY order_date) AS order_seq
    FROM orders
    WHERE status = 'completed'
)
SELECT
    DATE_TRUNC('month', order_date) AS month,   -- see CROSS-DATABASE NOTES below for MySQL/SQL Server
    SUM(CASE WHEN order_seq = 1 THEN 1 ELSE 0 END) AS new_customers,
    SUM(CASE WHEN order_seq > 1 THEN 1 ELSE 0 END) AS returning_orders
FROM customer_order_seq
GROUP BY DATE_TRUNC('month', order_date)
ORDER BY month;


-- 4c. Customers whose average order value is above the overall average (Subquery in HAVING)
SELECT
    c.customer_id,
    c.full_name,
    AVG(oi.quantity * oi.unit_price) AS avg_order_value
FROM customers c
JOIN orders o       ON o.customer_id = c.customer_id
JOIN order_items oi ON oi.order_id   = o.order_id
WHERE o.status = 'completed'
GROUP BY c.customer_id, c.full_name
HAVING AVG(oi.quantity * oi.unit_price) > (
    SELECT AVG(oi2.quantity * oi2.unit_price)
    FROM order_items oi2
    JOIN orders o2 ON o2.order_id = oi2.order_id
    WHERE o2.status = 'completed'
)
ORDER BY avg_order_value DESC;


-- 4d. Payment method breakdown & failure/refund rate (pure payments-table analytics)
SELECT
    method,
    COUNT(*)                                                       AS total_payments,
    SUM(CASE WHEN payment_status = 'success'  THEN 1 ELSE 0 END)   AS successful,
    SUM(CASE WHEN payment_status = 'failed'   THEN 1 ELSE 0 END)   AS failed,
    SUM(CASE WHEN payment_status = 'refunded' THEN 1 ELSE 0 END)   AS refunded,
    ROUND(
        100.0 * SUM(CASE WHEN payment_status = 'success' THEN 1 ELSE 0 END) / COUNT(*),
        1
    ) AS success_rate_pct
FROM payments
GROUP BY method
ORDER BY total_payments DESC;


-- ============================================================
-- 5. CROSS-DATABASE NOTES
--    This script targets PostgreSQL. If you run it on MySQL or
--    SQL Server, adjust the following:
-- ============================================================

-- (a) Relative date intervals — CURRENT_DATE - INTERVAL '6 months'
--     PostgreSQL : CURRENT_DATE - INTERVAL '6 months'
--     MySQL      : CURDATE() - INTERVAL 6 MONTH          -- no quotes around the number+unit
--     SQL Server : DATEADD(MONTH, -6, GETDATE())

-- (b) Truncating a date to the month — DATE_TRUNC('month', order_date)
--     PostgreSQL : DATE_TRUNC('month', order_date)
--     MySQL      : DATE_FORMAT(order_date, '%Y-%m-01')    -- or DATE_FORMAT(order_date, '%Y-%m') for a label
--     SQL Server : DATEFROMPARTS(YEAR(order_date), MONTH(order_date), 1)
--                  -- or FORMAT(order_date, 'yyyy-MM') if you only need a display label

-- (c) Auto-increment primary keys — SERIAL
--     PostgreSQL : SERIAL / GENERATED ALWAYS AS IDENTITY
--     MySQL      : INT ... AUTO_INCREMENT
--     SQL Server : INT ... IDENTITY(1,1)

-- (d) RANK() / DENSE_RANK() / ROW_NUMBER() and NOT EXISTS subqueries
--     are ANSI-SQL standard and work the same way across all three engines.
