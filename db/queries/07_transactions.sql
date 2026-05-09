-- ============================================================================
-- 07_transactions.sql — примеры транзакций и уровней изоляции
--
-- Запускать построчно в psql и параллельно во второй сессии для
-- демонстрации race condition. Полные сценарии — в docs/transactions-demo.md.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Простейшая атомарная транзакция
-- ----------------------------------------------------------------------------
BEGIN;
    SELECT fn_place_order(
        (SELECT tenant_id FROM tenants LIMIT 1),
        (SELECT branch_id FROM branches LIMIT 1),
        (SELECT table_id FROM restaurant_tables LIMIT 1),
        NULL, NULL, 'dine_in',
        '[{"menu_item_id": "00000000-0000-0000-0000-000000000000", "quantity": 1}]'::jsonb
    );
ROLLBACK;  -- ничего не сохраняем

-- ----------------------------------------------------------------------------
-- 2. SAVEPOINT: частичный откат
-- ----------------------------------------------------------------------------
BEGIN;
    INSERT INTO suppliers (tenant_id, name) VALUES
        ((SELECT tenant_id FROM tenants LIMIT 1), 'Test Supplier 1');
    SAVEPOINT sp1;
    INSERT INTO suppliers (tenant_id, name) VALUES
        ((SELECT tenant_id FROM tenants LIMIT 1), 'Test Supplier 2');
    ROLLBACK TO SAVEPOINT sp1;  -- откатываем только второй INSERT
    INSERT INTO suppliers (tenant_id, name) VALUES
        ((SELECT tenant_id FROM tenants LIMIT 1), 'Test Supplier 3');
COMMIT;  -- сохранены Supplier 1 и Supplier 3

-- ----------------------------------------------------------------------------
-- 3. READ COMMITTED (default): lost update на inventory
--    Сессия A:
BEGIN;
SELECT quantity FROM inventory
 WHERE branch_id = '...' AND ingredient_id = '...';
--    Одновременно сессия B делает то же самое и успевает UPDATE первой.
UPDATE inventory SET quantity = quantity - 10
 WHERE branch_id = '...' AND ingredient_id = '...';
COMMIT;
--    В итоге обе вычитают из одного и того же quantity → lost update.

-- ----------------------------------------------------------------------------
-- 4. SERIALIZABLE: одна из транзакций получит serialization_failure
--    и должна быть retried на уровне приложения.
-- ----------------------------------------------------------------------------
BEGIN ISOLATION LEVEL SERIALIZABLE;
SELECT quantity FROM inventory
 WHERE branch_id = '...' AND ingredient_id = '...';
UPDATE inventory SET quantity = quantity - 10
 WHERE branch_id = '...' AND ingredient_id = '...';
COMMIT;
-- Если параллельно другая сессия сделала UPDATE:
--   ERROR: could not serialize access due to concurrent update
--   HINT:  The transaction might succeed if retried.

-- ----------------------------------------------------------------------------
-- 5. SELECT ... FOR UPDATE: pessimistic locking
--    Этот паттерн используется внутри fn_place_order чтобы гарантировать
--    что никто другой не прочитает и не модифицирует inventory row
--    между нашим SELECT и UPDATE.
-- ----------------------------------------------------------------------------
BEGIN;
SELECT quantity FROM inventory
 WHERE branch_id = '...' AND ingredient_id = '...'
 FOR UPDATE;
-- Здесь любая другая транзакция с FOR UPDATE / UPDATE заблокируется.
UPDATE inventory SET quantity = quantity - 10
 WHERE branch_id = '...' AND ingredient_id = '...';
COMMIT;

-- ----------------------------------------------------------------------------
-- 6. CHECK constraint violation → автоматический rollback
-- ----------------------------------------------------------------------------
BEGIN;
INSERT INTO order_items (order_id, order_created_at, menu_item_id,
                          item_name_snapshot, unit_price_snapshot,
                          quantity, line_total)
VALUES ('00000000-0000-0000-0000-000000000000', NOW(),
        '00000000-0000-0000-0000-000000000000',
        'Test', -5, 1, -5);  -- CHECK(unit_price_snapshot >= 0) провалится
-- ERROR: new row for relation "order_items" violates check constraint
ROLLBACK;

-- ----------------------------------------------------------------------------
-- 7. Deadlock демо: две транзакции блокируют друг друга.
--    Сессия A: UPDATE inventory WHERE ing1 ... потом ing2
--    Сессия B: UPDATE inventory WHERE ing2 ... потом ing1
--    → Postgres детектит deadlock и убивает одну из транзакций.
-- ----------------------------------------------------------------------------
