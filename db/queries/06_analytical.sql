-- ============================================================================
-- 06_analytical.sql — бизнес-отчёты для дашборда
-- ============================================================================

-- 1. Revenue by hour of day — когда филиалы делают выручку.
SELECT
EXTRACT(HOUR FROM created_at)::int AS hour,
       COUNT(*) AS orders_count,
       SUM(total_amount) AS revenue,
       AVG(total_amount) AS avg_check
  FROM orders
 WHERE status = 'completed'
   AND created_at >= NOW() - interval '30 days'
 GROUP BY hour
 ORDER BY hour;

-- 2. Best day of week по филиалу.
SELECT
b.name AS branch,
       to_char(o.created_at, 'Day') AS day_of_week,
       COUNT(*) AS orders_count,
       SUM(o.total_amount) AS revenue
  FROM orders o
  INNER JOIN branches b ON o.branch_id = b.branch_id
 WHERE o.status = 'completed'
 GROUP BY b.name, to_char(o.created_at, 'Day'), EXTRACT(DOW FROM o.created_at)
 ORDER BY b.name, EXTRACT(DOW FROM o.created_at);

-- 3. Средний чек и количество позиций в заказе.
WITH order_stats AS (
    SELECT
o.order_id,
o.created_at,
o.total_amount,
           COUNT(oi.order_item_id) AS items_count,
           SUM(oi.quantity) AS total_qty
      FROM orders o
      INNER JOIN order_items oi
        ON o.order_id = oi.order_id AND o.created_at = oi.order_created_at
     WHERE o.status = 'completed'
     GROUP BY o.order_id, o.created_at, o.total_amount
)

SELECT
ROUND(AVG(total_amount), 2) AS avg_check,
       ROUND(AVG(items_count), 2)  AS avg_items,
       ROUND(AVG(total_qty), 2)    AS avg_qty
  FROM order_stats;

-- 4. Retention: % клиентов, вернувшихся в течение 30 дней после первого заказа.
WITH first_order AS (
    SELECT
customer_id,
MIN(created_at) AS first_at
      FROM orders
     WHERE customer_id IS NOT null AND status = 'completed'
     GROUP BY customer_id
),

returned AS (
    SELECT f.customer_id
      FROM first_order f
      INNER JOIN orders o ON f.customer_id = o.customer_id
     WHERE o.created_at > f.first_at
       AND o.created_at <= f.first_at + interval '30 days'
     GROUP BY f.customer_id
)

SELECT
    (SELECT COUNT(*) FROM first_order) AS total_customers,
    (SELECT COUNT(*) FROM returned)    AS returned_customers,
    ROUND(100.0 * (SELECT COUNT(*) FROM returned)
                  / NULLIF((SELECT COUNT(*) FROM first_order), 0), 2) AS retention_30d_pct;

-- 5. Inventory turnover: сколько раз за 30 дней обернулся склад ингредиента.
WITH consumed AS (
    SELECT
ingredient_id,
SUM(ABS(quantity_delta)) AS consumed_qty
      FROM inventory_movements
     WHERE movement_type = 'consumption'
       AND created_at >= NOW() - interval '30 days'
     GROUP BY ingredient_id
)

SELECT
i.name AS ingredient,
       SUM(inv.quantity) AS current_stock,
       COALESCE(c.consumed_qty, 0) AS consumed_30d,
       CASE WHEN SUM(inv.quantity) = 0 THEN null
            ELSE ROUND(COALESCE(c.consumed_qty, 0) / SUM(inv.quantity), 2)
       END AS turnover_ratio
  FROM ingredients i
  LEFT JOIN inventory inv ON i.ingredient_id = inv.ingredient_id
  LEFT JOIN consumed c    ON i.ingredient_id = c.ingredient_id
 GROUP BY i.ingredient_id, i.name, c.consumed_qty
 ORDER BY turnover_ratio DESC NULLS LAST
 LIMIT 20;

-- 6. Average prep time: от pending до ready (через order_status_history).
WITH status_times AS (
    SELECT
order_id,
order_created_at,
           MIN(changed_at) FILTER (WHERE new_status = 'pending')   AS pending_at,
           MIN(changed_at) FILTER (WHERE new_status = 'ready')     AS ready_at
      FROM order_status_history
     GROUP BY order_id, order_created_at
)

SELECT
    ROUND(AVG(EXTRACT(EPOCH FROM (ready_at - pending_at))) / 60, 2) AS avg_prep_minutes,
    COUNT(*) AS orders_measured
  FROM status_times
 WHERE ready_at IS NOT null AND pending_at IS NOT null;

-- 7. Full-text search по меню.
SELECT
menu_item_id,
name,
       ts_rank(search_vector, plainto_tsquery('simple', 'плов говядина')) AS rank
  FROM menu_items
 WHERE search_vector @@ plainto_tsquery('simple', 'плов говядина')
 ORDER BY rank DESC
 LIMIT 10;
