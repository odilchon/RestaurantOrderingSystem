-- ============================================================================
-- 04_subqueries.sql — scalar, correlated, EXISTS, IN, ANY, ALL, lateral
-- ============================================================================

-- 1. Scalar subquery: блюда дороже среднего в своей категории.
SELECT
mi.name,
mi.base_price,
c.name AS category
  FROM menu_items mi
  INNER JOIN categories c ON mi.category_id = c.category_id
 WHERE mi.base_price > (
     SELECT AVG(base_price)
       FROM menu_items mi2
      WHERE mi2.category_id = mi.category_id
 )
 ORDER BY c.name ASC, mi.base_price DESC;

-- 2. Correlated: последний заказ каждого клиента.
SELECT
u.full_name,
o.order_number,
o.total_amount,
o.created_at
  FROM users u
  INNER JOIN orders o ON u.user_id = o.customer_id
 WHERE o.created_at = (
     SELECT MAX(created_at)
       FROM orders o2
      WHERE o2.customer_id = u.user_id
 )
 ORDER BY o.created_at DESC
 LIMIT 20;

-- 3. EXISTS: клиенты, оставившие хотя бы один отзыв.
SELECT
u.user_id,
u.full_name,
u.email
  FROM users u
 WHERE EXISTS (
     SELECT 1 FROM reviews r WHERE r.customer_id = u.user_id
 );

-- 4. NOT EXISTS: клиенты без единого заказа.
SELECT
u.user_id,
u.full_name
  FROM users u
 WHERE NOT EXISTS (
     SELECT 1 FROM orders o WHERE o.customer_id = u.user_id
 )
 LIMIT 20;

-- 5. IN + subquery: все заказы в филиалах одного tenant-а.
SELECT
order_number,
branch_id,
total_amount
  FROM orders
 WHERE branch_id IN (
     SELECT branch_id FROM branches
      WHERE tenant_id = (SELECT tenant_id FROM tenants ORDER BY created_at LIMIT 1)
 )
 ORDER BY created_at DESC
 LIMIT 20;

-- 6. ANY: блюда дороже любого блюда категории 'drinks'.
SELECT
name,
base_price
  FROM menu_items
 WHERE base_price > ANY(
     SELECT mi.base_price
       FROM menu_items mi
       INNER JOIN categories c ON mi.category_id = c.category_id
      WHERE c.slug = 'drinks'
 )
 ORDER BY base_price
 LIMIT 15;

-- 7. ALL: блюда дороже всех блюд категории 'appetizers'.
SELECT
name,
base_price
  FROM menu_items
 WHERE base_price > ALL(
     SELECT mi.base_price
       FROM menu_items mi
       INNER JOIN categories c ON mi.category_id = c.category_id
      WHERE c.slug = 'appetizers'
 )
 ORDER BY base_price
 LIMIT 10;

-- 8. LATERAL: последние 3 заказа каждого клиента.
SELECT
u.full_name,
recent.order_number,
recent.total_amount,
recent.created_at
  FROM users u
  INNER JOIN LATERAL (
      SELECT
o.order_number,
o.total_amount,
o.created_at
        FROM orders o
       WHERE o.customer_id = u.user_id
       ORDER BY o.created_at DESC
       LIMIT 3
  ) recent ON true
 ORDER BY u.full_name ASC, recent.created_at DESC;

-- 9. Derived table: топ-3 филиала по выручке + их доля от tenant-а.
SELECT
*,
ROUND(100.0 * revenue / SUM(revenue) OVER (), 2) AS pct_of_total
  FROM (
      SELECT
b.name,
SUM(o.total_amount) AS revenue
        FROM orders o INNER JOIN branches b ON o.branch_id = b.branch_id
       WHERE o.status = 'completed'
       GROUP BY b.name
       ORDER BY revenue DESC
       LIMIT 3
  ) top3;
