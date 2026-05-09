-- ============================================================================
-- 05_indexes.sql
-- Индексы Restaurant Ordering System.
--
-- Стратегия:
--   1) B-tree на все FK (часто fk-джойны и cascade-проверки).
--   2) Составные индексы под реальные запросы дашборда и kitchen display.
--   3) Частичные индексы — для "горячих" подмножеств (активные заказы, активные бронирования).
--   4) Expression index — case-insensitive email/phone поиск.
--   5) GIN — для JSONB (settings, operating_hours) и tsvector (menu FTS).
--   6) BRIN — для append-only исторических столбцов (audit_log.changed_at).
--
-- Каждый индекс сопровождается COMMENT с обоснованием. Замеры
-- EXPLAIN ANALYZE до/после — в docs/indexing-report.md (Неделя 2).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Users & Auth
-- ----------------------------------------------------------------------------

-- Case-insensitive поиск по email. CITEXT уже case-insensitive,
-- но expression index на lower() — явно для демо "expression index".
CREATE INDEX IF NOT EXISTS idx_users_email_lower
    ON users (LOWER(email))
    WHERE email IS NOT null;
COMMENT ON INDEX idx_users_email_lower IS 'Expression index: case-insensitive login by email.';

CREATE INDEX IF NOT EXISTS idx_users_phone
    ON users (phone)
    WHERE phone IS NOT null;

CREATE INDEX IF NOT EXISTS idx_user_roles_user
    ON user_roles (user_id);
CREATE INDEX IF NOT EXISTS idx_user_roles_tenant_branch
    ON user_roles (tenant_id, branch_id)
    WHERE tenant_id IS NOT null;

-- Cleanup expired sessions — частый housekeeping запрос.
CREATE INDEX IF NOT EXISTS idx_sessions_expires_at
    ON sessions (expires_at)
    WHERE revoked_at IS null;
COMMENT ON INDEX idx_sessions_expires_at IS 'Partial index для cleanup активных сессий с истёкшим сроком.';

CREATE INDEX IF NOT EXISTS idx_sessions_user
    ON sessions (user_id);

-- ----------------------------------------------------------------------------
-- Restaurant structure
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_branches_tenant
    ON branches (tenant_id)
    WHERE is_active = true;

-- JSONB operating_hours — фильтры типа "у кого сегодня открыто в 22:00".
CREATE INDEX IF NOT EXISTS idx_branches_operating_hours_gin
    ON branches USING gin (operating_hours);
COMMENT ON INDEX idx_branches_operating_hours_gin IS 'GIN на JSONB operating_hours для запросов "открыт сейчас".';

CREATE INDEX IF NOT EXISTS idx_tenants_settings_gin
    ON tenants USING gin (settings);

CREATE INDEX IF NOT EXISTS idx_zones_branch
    ON zones (branch_id);

CREATE INDEX IF NOT EXISTS idx_tables_branch_status
    ON restaurant_tables (branch_id, status);
COMMENT ON INDEX idx_tables_branch_status IS 'Hostess dashboard: все столы филиала по статусу.';

CREATE INDEX IF NOT EXISTS idx_tables_zone
    ON restaurant_tables (zone_id);

-- ----------------------------------------------------------------------------
-- Menu
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_categories_tenant_parent
    ON categories (tenant_id, parent_id);

CREATE INDEX IF NOT EXISTS idx_menu_items_tenant_category
    ON menu_items (tenant_id, category_id)
    WHERE is_active = true;
COMMENT ON INDEX idx_menu_items_tenant_category IS 'Partial: витрина меню показывает только активные блюда.';

-- Full-text search на tsvector. Само поле обновляется триггером (09_triggers.sql).
CREATE INDEX IF NOT EXISTS idx_menu_items_search_vector
    ON menu_items USING gin (search_vector);
COMMENT ON INDEX idx_menu_items_search_vector IS 'GIN для full-text search по меню (ru+en).';

-- Trigram для fuzzy поиска (опечатки: "манты" / "манти").
CREATE INDEX IF NOT EXISTS idx_menu_items_name_trgm
    ON menu_items USING gin (name gin_trgm_ops);
COMMENT ON INDEX idx_menu_items_name_trgm IS 'Trigram для fuzzy-поиска по названию (опечатки, частичные совпадения).';

-- Активная цена — valid_to IS NULL, partial index.
CREATE INDEX IF NOT EXISTS idx_menu_item_prices_active
    ON menu_item_prices (menu_item_id)
    WHERE valid_to IS null;
COMMENT ON INDEX idx_menu_item_prices_active IS 'Partial: активная (текущая) цена блюда без сканирования истории.';

CREATE INDEX IF NOT EXISTS idx_menu_item_prices_item_period
    ON menu_item_prices (menu_item_id, valid_from DESC);

CREATE INDEX IF NOT EXISTS idx_menu_item_branch_availability_branch
    ON menu_item_branch_availability (branch_id)
    WHERE is_available = true;

-- ----------------------------------------------------------------------------
-- Inventory
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_inventory_ingredient
    ON inventory (ingredient_id);

-- Low-stock alerts — частый операционный запрос.
CREATE INDEX IF NOT EXISTS idx_inventory_low_stock
    ON inventory (branch_id, ingredient_id)
    INCLUDE (quantity);
COMMENT ON INDEX idx_inventory_low_stock IS 'Covering index для fn_check_low_stock: читает quantity без heap fetch.';

CREATE INDEX IF NOT EXISTS idx_inv_movements_branch_created
    ON inventory_movements (branch_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inv_movements_ingredient_created
    ON inventory_movements (ingredient_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_inv_movements_reference
    ON inventory_movements (reference_type, reference_id)
    WHERE reference_type IS NOT null;

CREATE INDEX IF NOT EXISTS idx_ingredients_allergens_gin
    ON ingredients USING gin (allergens);
COMMENT ON INDEX idx_ingredients_allergens_gin IS 'GIN на массив аллергенов: "блюда без глютена" через @>.';

-- ----------------------------------------------------------------------------
-- Purchase orders
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_purchase_orders_tenant_status
    ON purchase_orders (tenant_id, status);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_supplier
    ON purchase_orders (supplier_id);

CREATE INDEX IF NOT EXISTS idx_purchase_orders_branch_expected
    ON purchase_orders (branch_id, expected_at)
    WHERE status IN ('submitted', 'approved');

-- ----------------------------------------------------------------------------
-- Orders (partitioned — индексы автоматически создаются на всех партициях)
-- ----------------------------------------------------------------------------

-- Главный композитный индекс: визитка дашборда кассира.
CREATE INDEX IF NOT EXISTS idx_orders_tenant_branch_created
    ON orders (tenant_id, branch_id, created_at DESC);
COMMENT ON INDEX idx_orders_tenant_branch_created IS 'Главный композитный: списки заказов по филиалу за период.';

-- Partial: горячие активные заказы (99% запросов kitchen display).
CREATE INDEX IF NOT EXISTS idx_orders_active
    ON orders (branch_id, status, created_at DESC)
    WHERE status IN ('pending', 'confirmed', 'preparing', 'ready');
COMMENT ON INDEX idx_orders_active IS 'Partial: kitchen display видит только активные заказы. Мелкий и горячий.';

CREATE INDEX IF NOT EXISTS idx_orders_customer
    ON orders (customer_id, created_at DESC)
    WHERE customer_id IS NOT null;

CREATE INDEX IF NOT EXISTS idx_orders_waiter
    ON orders (waiter_id, created_at DESC)
    WHERE waiter_id IS NOT null;

CREATE INDEX IF NOT EXISTS idx_orders_table
    ON orders (table_id)
    WHERE table_id IS NOT null;

-- order_items — FK на composite (order_id, order_created_at)
CREATE INDEX IF NOT EXISTS idx_order_items_order
    ON order_items (order_id, order_created_at);

CREATE INDEX IF NOT EXISTS idx_order_items_menu_item
    ON order_items (menu_item_id);

CREATE INDEX IF NOT EXISTS idx_order_status_history_order
    ON order_status_history (order_id, order_created_at, changed_at);

CREATE INDEX IF NOT EXISTS idx_payments_order
    ON payments (order_id, order_created_at);

CREATE INDEX IF NOT EXISTS idx_payments_status_created
    ON payments (status, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_refunds_payment
    ON refunds (payment_id);

-- ----------------------------------------------------------------------------
-- Customer experience
-- ----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_reservations_branch_period
    ON reservations (branch_id, reserved_period);
COMMENT ON INDEX idx_reservations_branch_period IS 'Загрузка филиала: бронирования в заданном окне.';

CREATE INDEX IF NOT EXISTS idx_reservations_customer
    ON reservations (customer_id)
    WHERE customer_id IS NOT null;

-- GiST на tstzrange — support для EXCLUDE constraint уже есть,
-- но явный индекс ускоряет "бронирования, пересекающиеся с [X,Y)".
CREATE INDEX IF NOT EXISTS idx_reservations_period_gist
    ON reservations USING gist (table_id, reserved_period)
    WHERE status IN ('pending', 'confirmed', 'seated');

CREATE INDEX IF NOT EXISTS idx_loyalty_accounts_customer
    ON loyalty_accounts (customer_id);

CREATE INDEX IF NOT EXISTS idx_loyalty_transactions_account_created
    ON loyalty_transactions (loyalty_account_id, created_at DESC);

CREATE INDEX IF NOT EXISTS idx_reviews_branch_rating
    ON reviews (branch_id, rating, created_at DESC);
COMMENT ON INDEX idx_reviews_branch_rating IS 'Отзывы по филиалу, сортировка по рейтингу и дате.';

-- ----------------------------------------------------------------------------
-- Operations & Audit
-- ----------------------------------------------------------------------------

-- Активные смены (clock_out IS NULL) — для кто сейчас на работе.
CREATE INDEX IF NOT EXISTS idx_shifts_active
    ON shifts (branch_id, user_id)
    WHERE clock_out IS null;
COMMENT ON INDEX idx_shifts_active IS 'Partial: кто сейчас на смене в филиале (clock_out IS NULL).';

CREATE INDEX IF NOT EXISTS idx_shifts_user_clock_in
    ON shifts (user_id, clock_in DESC);

-- audit_log — append-only, BRIN на changed_at в разы компактнее B-tree.
CREATE INDEX IF NOT EXISTS idx_audit_log_changed_at_brin
    ON audit_log USING brin (changed_at) WITH (pages_per_range = 64);
COMMENT ON INDEX idx_audit_log_changed_at_brin IS 'BRIN: компактный индекс на append-only audit_log.changed_at.';

CREATE INDEX IF NOT EXISTS idx_audit_log_table_row
    ON audit_log (table_name, row_pk, changed_at DESC);
COMMENT ON INDEX idx_audit_log_table_row IS 'История изменений конкретной строки любой таблицы.';

CREATE INDEX IF NOT EXISTS idx_audit_log_changed_by
    ON audit_log (changed_by, changed_at DESC)
    WHERE changed_by IS NOT null;

CREATE INDEX IF NOT EXISTS idx_notifications_user_unread
    ON notifications (user_id, created_at DESC)
    WHERE read_at IS null;
COMMENT ON INDEX idx_notifications_user_unread IS 'Partial: непрочитанные уведомления пользователя.';
