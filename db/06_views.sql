-- ============================================================================
-- 06_views.sql
-- Regular views: часто используемые SELECT-ы, не требующие materialization.
-- Тяжёлая аналитика — в 07_materialized_views.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- v_active_menu: активные блюда с текущей ценой (join menu_item_prices).
-- Заменяет повторяющийся JOIN в 10+ местах приложения.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_active_menu AS
SELECT
    mi.menu_item_id,
    mi.tenant_id,
    mi.category_id,
    c.name                  AS category_name,
    mi.sku,
    mi.name,
    mi.description,
    COALESCE(p.price, mi.base_price) AS current_price,
    mi.preparation_minutes,
    mi.calories,
    mi.photo_url
FROM menu_items mi
INNER JOIN categories c ON mi.category_id = c.category_id
LEFT JOIN menu_item_prices p
       ON mi.menu_item_id = p.menu_item_id
      AND p.valid_to IS null
WHERE mi.is_active = true;
COMMENT ON VIEW v_active_menu IS 'Активное меню с актуальной ценой (либо из menu_item_prices, либо base_price).';

-- ----------------------------------------------------------------------------
-- v_order_summary: денормализованное представление заказа для API / чеков.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_order_summary AS
SELECT
    o.order_id,
    o.tenant_id,
    o.branch_id,
    b.name                  AS branch_name,
    o.order_number,
    o.status,
    o.order_type,
    o.created_at,
    o.total_amount,
    o.subtotal,
    o.tax_amount,
    o.service_charge,
    o.discount_amount,
    u_waiter.full_name      AS waiter_name,
    u_customer.full_name    AS customer_name,
    rt.table_number,
    (SELECT COUNT(*) FROM order_items oi
      WHERE oi.order_id = o.order_id
        AND oi.order_created_at = o.created_at) AS items_count,
    (SELECT COALESCE(SUM(p.amount), 0) FROM payments p
      WHERE p.order_id = o.order_id
        AND p.order_created_at = o.created_at
        AND p.status IN ('captured', 'authorized')) AS amount_paid
FROM orders o
INNER JOIN branches b ON o.branch_id = b.branch_id
LEFT JOIN users u_waiter   ON o.waiter_id = u_waiter.user_id
LEFT JOIN users u_customer ON o.customer_id = u_customer.user_id
LEFT JOIN restaurant_tables rt ON o.table_id = rt.table_id;
COMMENT ON VIEW v_order_summary IS 'Плоское представление заказа: для чеков, API списков, kitchen display.';

-- ----------------------------------------------------------------------------
-- v_low_stock: ингредиенты ниже reorder_level.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT
    i.branch_id,
    b.name              AS branch_name,
    i.ingredient_id,
    ing.name            AS ingredient_name,
    ing.unit,
    i.quantity,
    ing.reorder_level,
    (ing.reorder_level - i.quantity) AS shortfall
FROM inventory i
INNER JOIN ingredients ing ON i.ingredient_id = ing.ingredient_id
INNER JOIN branches b      ON i.branch_id = b.branch_id
WHERE i.quantity < ing.reorder_level
  AND ing.reorder_level > 0;
COMMENT ON VIEW v_low_stock IS 'Ингредиенты требующие пополнения. Используется в dashboard alerts и fn_check_low_stock.';

-- ----------------------------------------------------------------------------
-- v_table_occupancy: текущая загрузка столов (стол + активный заказ).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_table_occupancy AS
SELECT
    rt.branch_id,
    rt.table_id,
    rt.table_number,
    rt.capacity,
    rt.status                AS table_status,
    o.order_id               AS active_order_id,
    o.order_number           AS active_order_number,
    o.created_at             AS order_started_at,
    NOW() - o.created_at     AS seated_duration,
    o.total_amount           AS order_total
FROM restaurant_tables rt
LEFT JOIN LATERAL (
    SELECT
o.order_id,
o.order_number,
o.created_at,
o.total_amount
    FROM orders o
    WHERE o.table_id = rt.table_id
      AND o.status IN ('pending', 'confirmed', 'preparing', 'ready', 'served')
    ORDER BY o.created_at DESC
    LIMIT 1
) o ON true;
COMMENT ON VIEW v_table_occupancy IS 'Hostess dashboard: столы + текущий активный заказ. LATERAL гарантирует один активный заказ на стол.';

-- ----------------------------------------------------------------------------
-- v_customer_orders: история заказов клиента с агрегатами.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_customer_orders AS
SELECT
    customer_id,
    tenant_id,
    COUNT(*)                         AS orders_count,
    SUM(total_amount)                AS lifetime_spent,
    AVG(total_amount)                AS avg_order_value,
    MIN(created_at)                  AS first_order_at,
    MAX(created_at)                  AS last_order_at
FROM orders
WHERE customer_id IS NOT null
  AND status NOT IN ('cancelled', 'draft')
GROUP BY customer_id, tenant_id;
COMMENT ON VIEW v_customer_orders IS 'Агрегаты по клиенту: history, LTV, частота. Для CRM и сегментации.';
