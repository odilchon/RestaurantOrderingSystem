-- ============================================================================
-- 02_joins.sql — INNER / LEFT / RIGHT / FULL / SELF / CROSS joins
-- ============================================================================

-- 1. INNER JOIN: заказы с данными филиала и официанта.
SELECT
o.order_number,
o.created_at,
o.total_amount,
       b.name AS branch_name,
u.full_name AS waiter_name
  FROM orders o
 INNER JOIN branches b ON o.branch_id = b.branch_id
 INNER JOIN users u    ON o.waiter_id   = u.user_id
 WHERE o.status = 'completed'
 ORDER BY o.created_at DESC
 LIMIT 20;

-- 2. LEFT JOIN: все блюда + сколько раз заказаны (NULL если ни разу).
SELECT
mi.menu_item_id,
mi.name,
       COUNT(oi.order_item_id) AS times_ordered
  FROM menu_items mi
  LEFT JOIN order_items oi ON mi.menu_item_id = oi.menu_item_id
 GROUP BY mi.menu_item_id, mi.name
 ORDER BY times_ordered DESC
 LIMIT 20;

-- 3. RIGHT JOIN: все столы, даже без активных заказов.
SELECT
rt.table_number,
rt.capacity,
rt.status,
       o.order_number,
o.total_amount
  FROM orders o
 RIGHT JOIN restaurant_tables rt
        ON o.table_id = rt.table_id
       AND o.status IN ('pending', 'preparing', 'ready')
 ORDER BY rt.table_number;

-- 4. FULL OUTER JOIN: несоответствия меню и inventory (блюда без ингредиентов
-- в рецептуре и ингредиенты без блюд).
SELECT
mi.name AS menu_item,
mii.ingredient_id,
ing.name AS ingredient
  FROM menu_items mi
  FULL OUTER JOIN menu_item_ingredients mii ON mi.menu_item_id = mii.menu_item_id
  FULL OUTER JOIN ingredients ing          ON mii.ingredient_id = ing.ingredient_id
 WHERE mii.menu_item_id IS null OR mi.menu_item_id IS null;

-- 5. SELF JOIN: категории с их родителями.
SELECT
c.name AS category,
parent.name AS parent_category
  FROM categories c
  LEFT JOIN categories parent ON c.parent_id = parent.category_id
 ORDER BY parent.name NULLS FIRST, c.name;

-- 6. CROSS JOIN: все комбинации филиал × категория меню (матрица доступности).
SELECT
b.name AS branch,
c.name AS category
  FROM branches b
 CROSS JOIN categories c
 WHERE b.tenant_id = c.tenant_id
   AND b.is_active = true
 ORDER BY b.name, c.name
 LIMIT 50;

-- 7. Multi-join: заказ со всеми позициями и именами блюд.
SELECT
o.order_number,
o.status,
       oi.quantity,
oi.item_name_snapshot,
oi.unit_price_snapshot,
oi.line_total
  FROM orders o
  INNER JOIN order_items oi
    ON o.order_id = oi.order_id
   AND o.created_at = oi.order_created_at
 WHERE o.order_id = (SELECT order_id FROM orders ORDER BY created_at DESC LIMIT 1);

-- 8. Join с materialized view: топ блюд филиала.
SELECT
b.name AS branch,
m.menu_item_name,
m.units_sold,
m.revenue,
m.revenue_rank
  FROM mv_top_menu_items_30d m
  INNER JOIN branches b ON m.branch_id = b.branch_id
 WHERE m.revenue_rank <= 5
 ORDER BY b.name, m.revenue_rank;
