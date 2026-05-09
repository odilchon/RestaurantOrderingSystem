-- ============================================================================
-- 03_aggregates.sql — GROUP BY, HAVING, ROLLUP, CUBE, GROUPING SETS, FILTER
-- ============================================================================

-- 1. Выручка и средний чек по филиалу за 30 дней.
SELECT
b.name,
       COUNT(o.order_id) AS orders_count,
       SUM(o.total_amount) AS revenue,
       AVG(o.total_amount) AS avg_check,
       MIN(o.total_amount) AS min_check,
       MAX(o.total_amount) AS max_check
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
   AND o.created_at >= NOW() - INTERVAL '30 days'
 GROUP BY b.name
 ORDER BY revenue DESC;

-- 2. HAVING: филиалы с выручкой > 100,000 сом.
SELECT
b.name,
SUM(o.total_amount) AS revenue
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
 GROUP BY b.name
HAVING SUM(o.total_amount) > 100000
 ORDER BY revenue DESC;

-- 3. ROLLUP: выручка по филиалу и дате + subtotal + grand total.
SELECT
b.name AS branch,
       date_trunc('day', o.created_at)::DATE AS day,
       SUM(o.total_amount) AS revenue
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
   AND o.created_at >= NOW() - INTERVAL '7 days'
 GROUP BY ROLLUP (b.name, date_trunc('day', o.created_at))
 ORDER BY branch NULLS LAST, day NULLS LAST;

-- 4. CUBE: кросс-аналитика по филиалу и типу заказа.
SELECT
b.name AS branch,
o.order_type,
       COUNT(*) AS orders_count,
       SUM(o.total_amount) AS revenue
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
 GROUP BY CUBE (b.name, o.order_type)
 ORDER BY branch NULLS LAST, order_type NULLS LAST;

-- 5. GROUPING SETS: выручка по филиалу и отдельно по часу дня.
SELECT
b.name AS branch,
       EXTRACT(HOUR FROM o.created_at)::INT AS hour_of_day,
       SUM(o.total_amount) AS revenue
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
 GROUP BY GROUPING SETS ((b.name), (hour_of_day), ())
 ORDER BY branch NULLS LAST, hour_of_day NULLS LAST;

-- 6. FILTER: одновременно total и по подтипам — без подзапросов.
SELECT
b.name AS branch,
       COUNT(*) AS total_orders,
       COUNT(*) FILTER (WHERE o.order_type = 'dine_in')  AS dine_in,
       COUNT(*) FILTER (WHERE o.order_type = 'takeaway') AS takeaway,
       COUNT(*) FILTER (WHERE o.order_type = 'delivery') AS delivery,
       SUM(o.total_amount) FILTER (WHERE o.status = 'completed') AS completed_revenue,
       SUM(o.total_amount) FILTER (WHERE o.status = 'cancelled') AS cancelled_value
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.created_at >= NOW() - INTERVAL '30 days'
 GROUP BY b.name;

-- 7. Процент отменённых заказов по филиалу.
SELECT
b.name,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE o.status = 'cancelled') AS cancelled,
       ROUND(100.0 * COUNT(*) FILTER (WHERE o.status = 'cancelled') / NULLIF(COUNT(*), 0), 2)
           AS cancel_rate_pct
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 GROUP BY b.name
 ORDER BY cancel_rate_pct DESC NULLS LAST;
