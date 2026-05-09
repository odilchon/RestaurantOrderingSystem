-- ============================================================================
-- 05_cte_window.sql — CTE (включая рекурсивные) и window functions
-- ============================================================================

-- 1. CTE: дневная выручка + running total.
WITH daily AS (
    SELECT
date_trunc('day', created_at)::date AS day,
           SUM(total_amount) AS revenue
      FROM orders
     WHERE status = 'completed'
       AND created_at >= NOW() - interval '30 days'
     GROUP BY day
)

SELECT
day,
revenue,
       SUM(revenue) OVER (ORDER BY day) AS running_total,
       AVG(revenue) OVER (ORDER BY day ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS rolling_7d_avg
  FROM daily
 ORDER BY day;

-- 2. ROW_NUMBER: удалить дубликаты заказов (демо — какие строки оставить).
WITH ranked AS (
    SELECT
order_id,
created_at,
order_number,
           ROW_NUMBER() OVER (PARTITION BY tenant_id, order_number ORDER BY created_at DESC) AS rn
      FROM orders
)

SELECT
order_id,
order_number
  FROM ranked
 WHERE rn > 1;

-- 3. RANK и DENSE_RANK: ранжирование блюд по выручке.
SELECT
oi.menu_item_id,
oi.item_name_snapshot,
       SUM(oi.line_total) AS revenue,
       RANK()       OVER (ORDER BY SUM(oi.line_total) DESC) AS rnk,
       DENSE_RANK() OVER (ORDER BY SUM(oi.line_total) DESC) AS dense_rnk,
       PERCENT_RANK() OVER (ORDER BY SUM(oi.line_total) DESC) AS pct_rank
  FROM order_items oi
 GROUP BY oi.menu_item_id, oi.item_name_snapshot
 ORDER BY revenue DESC
 LIMIT 20;

-- 4. LAG / LEAD: сравнение выручки с предыдущим и следующим днём.
WITH daily AS (
    SELECT
branch_id,
           date_trunc('day', created_at)::date AS day,
           SUM(total_amount) AS revenue
      FROM orders
     WHERE status = 'completed'
     GROUP BY branch_id, day
)

SELECT
branch_id,
day,
revenue,
       LAG(revenue)  OVER (PARTITION BY branch_id ORDER BY day) AS prev_day,
       LEAD(revenue) OVER (PARTITION BY branch_id ORDER BY day) AS next_day,
       revenue - LAG(revenue) OVER (PARTITION BY branch_id ORDER BY day) AS day_over_day_delta
  FROM daily
 ORDER BY branch_id, day;

-- 5. NTILE: квантили чека.
SELECT
order_number,
total_amount,
       NTILE(4) OVER (ORDER BY total_amount) AS quartile
  FROM orders
 WHERE status = 'completed'
 ORDER BY total_amount DESC
 LIMIT 40;

-- 6. FIRST_VALUE / LAST_VALUE: первый и последний заказ клиента в одной строке.
SELECT DISTINCT
customer_id,
       FIRST_VALUE(order_number) OVER w AS first_order,
       FIRST_VALUE(created_at)   OVER w AS first_at,
       LAST_VALUE(order_number)  OVER w AS last_order,
       LAST_VALUE(created_at)    OVER w AS last_at
  FROM orders
 WHERE customer_id IS NOT null
WINDOW w AS (
    PARTITION BY customer_id
    ORDER BY created_at
    RANGE BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
);

-- 7. РЕКУРСИВНАЯ CTE: обход иерархии категорий от корня до листа с путём.
WITH RECURSIVE tree AS (
    SELECT
category_id,
parent_id,
name,
name::text AS path,
1 AS depth
      FROM categories
     WHERE parent_id IS null
    UNION ALL
    SELECT
c.category_id,
c.parent_id,
c.name,
           t.path || ' > ' || c.name,
           t.depth + 1
      FROM categories c
      INNER JOIN tree t ON c.parent_id = t.category_id
)

SELECT
depth,
path
FROM tree ORDER BY path;

-- 8. Cohort: заказы по неделе когорты клиента (когорта = неделя первого заказа).
WITH first_order AS (
    SELECT
customer_id,
           date_trunc('week', MIN(created_at))::date AS cohort_week
      FROM orders
     WHERE customer_id IS NOT null
     GROUP BY customer_id
),

cohort_activity AS (
    SELECT
f.cohort_week,
           date_trunc('week', o.created_at)::date AS activity_week,
           COUNT(DISTINCT o.customer_id) AS active_customers
      FROM first_order f
      INNER JOIN orders o ON f.customer_id = o.customer_id
     GROUP BY f.cohort_week, date_trunc('week', o.created_at)
)

SELECT
cohort_week,
activity_week,
       (activity_week - cohort_week)/7 AS weeks_since_first,
       active_customers
  FROM cohort_activity
 ORDER BY cohort_week, activity_week;
