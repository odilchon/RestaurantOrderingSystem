-- ============================================================================
-- 07_materialized_views.sql
-- Materialized views для тяжёлой аналитики.
--
-- Стратегия refresh:
--   mv_daily_revenue_by_branch — REFRESH каждый час (cron / pg_cron).
--   mv_top_menu_items_30d      — REFRESH раз в сутки ночью.
--
-- Все MV создаются WITH NO DATA — первичный REFRESH делается после seed
-- в 12_seed.sql (или руками после загрузки данных).
-- Все MV имеют UNIQUE index — без него REFRESH CONCURRENTLY невозможен.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- mv_daily_revenue_by_branch
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_daily_revenue_by_branch AS
SELECT
    o.tenant_id,
    o.branch_id,
    date_trunc('day', o.created_at)::date AS revenue_date,
    COUNT(*)                              AS orders_count,
    SUM(o.subtotal)                       AS subtotal_sum,
    SUM(o.tax_amount)                     AS tax_sum,
    SUM(o.service_charge)                 AS service_sum,
    SUM(o.discount_amount)                AS discount_sum,
    SUM(o.total_amount)                   AS revenue_total,
    AVG(o.total_amount)                   AS avg_check
FROM orders o
WHERE o.status IN ('completed', 'served')
GROUP BY o.tenant_id, o.branch_id, date_trunc('day', o.created_at)
WITH NO DATA;
COMMENT ON MATERIALIZED VIEW mv_daily_revenue_by_branch IS
    'Дневная выручка по филиалу: для дашборда и исторических графиков. Refresh hourly.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_daily_revenue_branch_day
    ON mv_daily_revenue_by_branch (tenant_id, branch_id, revenue_date);

-- ----------------------------------------------------------------------------
-- mv_top_menu_items_30d
-- Топ блюд по выручке за последние 30 дней. Для отчёта "best sellers".
-- ----------------------------------------------------------------------------
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_top_menu_items_30d AS
SELECT
    o.tenant_id,
    o.branch_id,
    oi.menu_item_id,
    mi.name                       AS menu_item_name,
    SUM(oi.quantity)              AS units_sold,
    SUM(oi.line_total)            AS revenue,
    COUNT(DISTINCT o.order_id)    AS orders_containing,
    RANK() OVER (
        PARTITION BY o.tenant_id, o.branch_id
        ORDER BY SUM(oi.line_total) DESC
    ) AS revenue_rank
FROM order_items oi
INNER JOIN orders o
      ON oi.order_id = o.order_id
     AND oi.order_created_at = o.created_at
INNER JOIN menu_items mi ON oi.menu_item_id = mi.menu_item_id
WHERE o.status IN ('completed', 'served')
  AND o.created_at >= NOW() - interval '30 days'
GROUP BY o.tenant_id, o.branch_id, oi.menu_item_id, mi.name
WITH NO DATA;
COMMENT ON MATERIALIZED VIEW mv_top_menu_items_30d IS
    'Топ блюд по выручке за 30 дней с window RANK. Refresh daily.';

CREATE UNIQUE INDEX IF NOT EXISTS uq_mv_top_menu_items_30d
    ON mv_top_menu_items_30d (tenant_id, branch_id, menu_item_id);

-- ----------------------------------------------------------------------------
-- Helper: REFRESH всех MV одной командой (для cron).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION refresh_all_materialized_views(p_concurrently boolean DEFAULT true)
RETURNS void AS $$
BEGIN
    IF p_concurrently THEN
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_revenue_by_branch;
        REFRESH MATERIALIZED VIEW CONCURRENTLY mv_top_menu_items_30d;
    ELSE
        REFRESH MATERIALIZED VIEW mv_daily_revenue_by_branch;
        REFRESH MATERIALIZED VIEW mv_top_menu_items_30d;
    END IF;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION refresh_all_materialized_views(boolean) IS
    'Обновляет все MV. p_concurrently=FALSE для первичного REFRESH после WITH NO DATA.';
