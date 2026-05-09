-- ============================================================================
-- 01_basic.sql — SELECT, WHERE, ORDER BY, LIMIT, DISTINCT, IN, BETWEEN, LIKE
-- ============================================================================

-- 1. Все активные филиалы, отсортированные по названию.
SELECT tenant_id, code, name, address, timezone
  FROM branches
 WHERE is_active = TRUE
 ORDER BY name;

-- 2. Топ-10 самых дорогих активных блюд одного tenant-а.
SELECT sku, name, base_price
  FROM menu_items
 WHERE tenant_id = (SELECT tenant_id FROM tenants ORDER BY created_at LIMIT 1)
   AND is_active = TRUE
 ORDER BY base_price DESC
 LIMIT 10;

-- 3. Заказы за последние 7 дней по статусам.
SELECT status, COUNT(*) AS cnt
  FROM orders
 WHERE created_at >= NOW() - INTERVAL '7 days'
 GROUP BY status
 ORDER BY cnt DESC;

-- 4. Клиенты с email содержащим 'gmail' (ILIKE — case-insensitive).
SELECT user_id, full_name, email
  FROM users
 WHERE email ILIKE '%gmail%'
 ORDER BY created_at DESC
 LIMIT 20;

-- 5. Столы вместимостью от 4 до 8 (BETWEEN).
SELECT table_number, capacity, status
  FROM restaurant_tables
 WHERE capacity BETWEEN 4 AND 8
 ORDER BY capacity, table_number;

-- 6. Различные tier программы лояльности (DISTINCT).
SELECT DISTINCT tier
  FROM loyalty_accounts
 ORDER BY tier;

-- 7. Заказы конкретных типов (IN).
SELECT order_id, order_number, order_type, total_amount
  FROM orders
 WHERE order_type IN ('dine_in', 'takeaway')
   AND status = 'completed'
 ORDER BY created_at DESC
 LIMIT 15;

-- 8. Низкий рейтинг: отзывы 1-2 звезды с комментарием.
SELECT review_id, rating, comment, created_at
  FROM reviews
 WHERE rating <= 2
   AND comment IS NOT NULL
 ORDER BY created_at DESC;

-- 9. Активные бронирования на сегодня.
SELECT reservation_id, guest_name, party_size, reserved_period
  FROM reservations
 WHERE status IN ('pending', 'confirmed')
   AND lower(reserved_period)::date = CURRENT_DATE
 ORDER BY lower(reserved_period);

-- 10. Пагинация: вторая страница меню по 20 штук.
SELECT menu_item_id, name, base_price
  FROM menu_items
 WHERE is_active = TRUE
 ORDER BY name
 OFFSET 20 LIMIT 20;
