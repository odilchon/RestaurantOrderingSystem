-- ============================================================================
-- 03_schema.sql
-- Полная DDL схема Restaurant Ordering System.
-- Все таблицы в 3NF, каждая с COMMENT ON, FK с явными ON DELETE/UPDATE,
-- CHECK/UNIQUE/EXCLUDE ограничениями.
-- orders — создаётся как partitioned table (PARTITION BY RANGE), сами
-- партиции — в 04_partitions.sql.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Section 1. Tenancy & Auth
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS tenants (
    tenant_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    slug            TEXT NOT NULL UNIQUE
        CHECK (slug ~ '^[a-z0-9][a-z0-9_-]{1,62}$'),
    name            TEXT NOT NULL,
    settings        JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE tenants IS 'SaaS-клиенты платформы: ресторанные бренды / сети. Корень tenant isolation.';
COMMENT ON COLUMN tenants.slug IS 'URL-friendly идентификатор, используется в поддоменах и публичных ссылках.';
COMMENT ON COLUMN tenants.settings IS 'Произвольные настройки tenant (валюта, налоги, часовой пояс) — JSONB для гибкости.';

CREATE TABLE IF NOT EXISTS users (
    user_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           CITEXT,
    phone           TEXT,
    password_hash   TEXT NOT NULL,
    full_name       TEXT NOT NULL,
    locale          TEXT NOT NULL DEFAULT 'ru'
        CHECK (locale IN ('ru', 'en', 'ky')),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    last_login_at   TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT users_email_or_phone CHECK (email IS NOT NULL OR phone IS NOT NULL),
    CONSTRAINT users_email_unique UNIQUE (email),
    CONSTRAINT users_phone_unique UNIQUE (phone)
);
COMMENT ON TABLE users IS 'Все пользователи системы: сотрудники tenant-ов и конечные клиенты. Один user может иметь роли в разных tenant/branch.';
COMMENT ON COLUMN users.password_hash IS 'bcrypt хэш через passlib; никогда не хранить plain text.';

-- Привязка пользователя к роли в контексте tenant/branch. Один user может
-- быть, например, manager в одном филиале и waiter в другом.
CREATE TABLE IF NOT EXISTS user_roles (
    user_role_id    BIGSERIAL PRIMARY KEY,
    user_id         UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    tenant_id       UUID REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    branch_id       UUID, -- FK добавится после создания branches
    role            USER_ROLE NOT NULL,
    granted_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    granted_by      UUID REFERENCES users(user_id) ON DELETE SET NULL,
    -- super_admin и customer не привязаны к tenant
    CONSTRAINT user_roles_tenant_scope CHECK (
        (role IN ('super_admin', 'customer') AND tenant_id IS NULL)
        OR (role NOT IN ('super_admin', 'customer') AND tenant_id IS NOT NULL)
    ),
    CONSTRAINT user_roles_unique UNIQUE NULLS NOT DISTINCT (user_id, tenant_id, branch_id, role)
);
COMMENT ON TABLE user_roles IS 'M:N users<->roles с привязкой к tenant/branch. NULLS NOT DISTINCT предотвращает дубликаты для nullable scope.';

CREATE TABLE IF NOT EXISTS sessions (
    session_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    token_hash      TEXT NOT NULL UNIQUE,
    user_agent      TEXT,
    ip_address      INET,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at      TIMESTAMPTZ NOT NULL,
    revoked_at      TIMESTAMPTZ,
    CONSTRAINT sessions_expiry CHECK (expires_at > created_at)
);
COMMENT ON TABLE sessions IS 'Активные сессии: используется для revoke и демо индекса по expires_at при cleanup.';

-- ----------------------------------------------------------------------------
-- Section 2. Restaurant structure
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS branches (
    branch_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    code            TEXT NOT NULL,
    name            TEXT NOT NULL,
    address         TEXT NOT NULL,
    latitude        NUMERIC(9, 6) CHECK (latitude BETWEEN -90 AND 90),
    longitude       NUMERIC(9, 6) CHECK (longitude BETWEEN -180 AND 180),
    phone           TEXT,
    operating_hours JSONB NOT NULL DEFAULT '{}'::JSONB,
    timezone        TEXT NOT NULL DEFAULT 'Asia/Bishkek',
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT branches_tenant_code_unique UNIQUE (tenant_id, code)
);
COMMENT ON TABLE branches IS 'Физические филиалы ресторана внутри tenant-а.';
COMMENT ON COLUMN branches.operating_hours IS 'JSONB формата {"mon": ["09:00","23:00"], ...} — гибкое расписание.';

-- Добавляем отложенный FK user_roles.branch_id -> branches
ALTER TABLE user_roles
    ADD CONSTRAINT user_roles_branch_fk
    FOREIGN KEY (branch_id) REFERENCES branches(branch_id) ON DELETE CASCADE;

CREATE TABLE IF NOT EXISTS zones (
    zone_id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    description     TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT zones_branch_name_unique UNIQUE (branch_id, name)
);
COMMENT ON TABLE zones IS 'Залы и секции внутри филиала: терраса, VIP, основной зал.';

CREATE TABLE IF NOT EXISTS restaurant_tables (
    table_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    zone_id         UUID NOT NULL REFERENCES zones(zone_id) ON DELETE CASCADE,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    table_number    TEXT NOT NULL,
    capacity        SMALLINT NOT NULL CHECK (capacity BETWEEN 1 AND 50),
    status          TABLE_STATUS NOT NULL DEFAULT 'available',
    qr_code         TEXT UNIQUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT tables_branch_number_unique UNIQUE (branch_id, table_number)
);
COMMENT ON TABLE restaurant_tables IS 'Столы для обслуживания и self-order через QR. Имя экранировано от системной TABLE.';

-- ----------------------------------------------------------------------------
-- Section 3. Menu & Inventory
-- ----------------------------------------------------------------------------

-- Иерархические категории: self-reference для подкатегорий.
CREATE TABLE IF NOT EXISTS categories (
    category_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    parent_id       UUID REFERENCES categories(category_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    slug            TEXT NOT NULL,
    sort_order      INTEGER NOT NULL DEFAULT 0,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT categories_tenant_slug_unique UNIQUE (tenant_id, slug),
    CONSTRAINT categories_no_self_parent CHECK (parent_id IS NULL OR parent_id <> category_id)
);
COMMENT ON TABLE categories IS 'Иерархические категории меню (self-referencing). Глубина не ограничена технически, на уровне приложения — 3 уровня.';

CREATE TABLE IF NOT EXISTS menu_items (
    menu_item_id    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    category_id     UUID NOT NULL REFERENCES categories(category_id) ON DELETE RESTRICT,
    sku             TEXT NOT NULL,
    name            TEXT NOT NULL,
    description     TEXT,
    base_price      NUMERIC(12, 2) NOT NULL CHECK (base_price >= 0),
    photo_url       TEXT,
    preparation_minutes SMALLINT CHECK (preparation_minutes IS NULL OR preparation_minutes >= 0),
    calories        INTEGER CHECK (calories IS NULL OR calories >= 0),
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    search_vector   TSVECTOR,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT menu_items_tenant_sku_unique UNIQUE (tenant_id, sku)
);
COMMENT ON TABLE menu_items IS 'Блюда меню. base_price — текущая цена, история — в menu_item_prices. search_vector обновляется триггером.';

CREATE TABLE IF NOT EXISTS menu_item_translations (
    menu_item_id    UUID NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE CASCADE,
    locale          TEXT NOT NULL CHECK (locale IN ('ru', 'en', 'ky')),
    name            TEXT NOT NULL,
    description     TEXT,
    PRIMARY KEY (menu_item_id, locale)
);
COMMENT ON TABLE menu_item_translations IS 'Локализация названий и описаний блюд: ru/en/ky для рынка КГ.';

-- История цен вместо перезаписи: valid_from/valid_to, активная цена —
-- та, у которой valid_to IS NULL.
CREATE TABLE IF NOT EXISTS menu_item_prices (
    price_id        BIGSERIAL PRIMARY KEY,
    menu_item_id    UUID NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE CASCADE,
    price           NUMERIC(12, 2) NOT NULL CHECK (price >= 0),
    valid_from      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to        TIMESTAMPTZ,
    changed_by      UUID REFERENCES users(user_id) ON DELETE SET NULL,
    CONSTRAINT price_period CHECK (valid_to IS NULL OR valid_to > valid_from)
);
COMMENT ON TABLE menu_item_prices IS 'Полная история цен блюд для аналитики маржи и аудита. Активная запись — valid_to IS NULL.';

CREATE TABLE IF NOT EXISTS menu_item_branch_availability (
    menu_item_id    UUID NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE CASCADE,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    is_available    BOOLEAN NOT NULL DEFAULT TRUE,
    price_override  NUMERIC(12, 2) CHECK (price_override IS NULL OR price_override >= 0),
    PRIMARY KEY (menu_item_id, branch_id)
);
COMMENT ON TABLE menu_item_branch_availability IS 'Какие блюда доступны в каком филиале + опциональное переопределение цены.';

CREATE TABLE IF NOT EXISTS ingredients (
    ingredient_id   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    unit            TEXT NOT NULL CHECK (unit IN ('g', 'kg', 'ml', 'l', 'pcs')),
    allergens       TEXT[] NOT NULL DEFAULT '{}',
    reorder_level   NUMERIC(12, 3) NOT NULL DEFAULT 0 CHECK (reorder_level >= 0),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT ingredients_tenant_name_unique UNIQUE (tenant_id, name)
);
COMMENT ON TABLE ingredients IS 'Каталог ингредиентов для учёта склада и расчёта себестоимости.';

CREATE TABLE IF NOT EXISTS menu_item_ingredients (
    menu_item_id    UUID NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE CASCADE,
    ingredient_id   UUID NOT NULL REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    quantity        NUMERIC(12, 3) NOT NULL CHECK (quantity > 0),
    PRIMARY KEY (menu_item_id, ingredient_id)
);
COMMENT ON TABLE menu_item_ingredients IS 'Рецептура: сколько каждого ингредиента нужно на одну порцию блюда.';

CREATE TABLE IF NOT EXISTS inventory (
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    ingredient_id   UUID NOT NULL REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    quantity        NUMERIC(12, 3) NOT NULL DEFAULT 0 CHECK (quantity >= 0),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (branch_id, ingredient_id)
);
COMMENT ON TABLE inventory IS 'Текущие остатки ингредиентов по филиалам. Обновляется триггером на inventory_movements.';

CREATE TABLE IF NOT EXISTS inventory_movements (
    movement_id     BIGSERIAL PRIMARY KEY,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    ingredient_id   UUID NOT NULL REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    movement_type   INVENTORY_MOVEMENT_TYPE NOT NULL,
    quantity_delta  NUMERIC(12, 3) NOT NULL,
    reference_type  TEXT,
    reference_id    TEXT,
    notes           TEXT,
    performed_by    UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT inv_movement_delta_sign CHECK (
        (movement_type IN ('purchase', 'transfer_in', 'return') AND quantity_delta > 0)
        OR (movement_type IN ('consumption', 'waste', 'transfer_out') AND quantity_delta < 0)
        OR (movement_type = 'adjustment' AND quantity_delta <> 0)
    )
);
COMMENT ON TABLE inventory_movements IS 'Event-sourcing журнал движений склада. reference_type/id связывают движение с заказом, закупкой и т.п.';

CREATE TABLE IF NOT EXISTS suppliers (
    supplier_id     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    contact_name    TEXT,
    phone           TEXT,
    email           CITEXT,
    address         TEXT,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE suppliers IS 'Поставщики ингредиентов.';

CREATE TABLE IF NOT EXISTS purchase_orders (
    purchase_order_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    supplier_id     UUID NOT NULL REFERENCES suppliers(supplier_id) ON DELETE RESTRICT,
    status          PURCHASE_ORDER_STATUS NOT NULL DEFAULT 'draft',
    total_amount    NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    expected_at     DATE,
    received_at     TIMESTAMPTZ,
    notes           TEXT,
    created_by      UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE purchase_orders IS 'Закупочные заказы поставщикам.';

CREATE TABLE IF NOT EXISTS purchase_order_items (
    purchase_order_item_id BIGSERIAL PRIMARY KEY,
    purchase_order_id UUID NOT NULL REFERENCES purchase_orders(purchase_order_id) ON DELETE CASCADE,
    ingredient_id   UUID NOT NULL REFERENCES ingredients(ingredient_id) ON DELETE RESTRICT,
    quantity        NUMERIC(12, 3) NOT NULL CHECK (quantity > 0),
    unit_price      NUMERIC(12, 2) NOT NULL CHECK (unit_price >= 0),
    CONSTRAINT po_item_unique UNIQUE (purchase_order_id, ingredient_id)
);
COMMENT ON TABLE purchase_order_items IS 'Позиции закупочного заказа.';

-- ----------------------------------------------------------------------------
-- Section 4. Orders & Payments
-- orders — PARTITIONED by created_at (monthly). Партиции — в 04_partitions.sql.
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS orders (
    order_id        UUID NOT NULL DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE RESTRICT,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE RESTRICT,
    table_id        UUID REFERENCES restaurant_tables(table_id) ON DELETE SET NULL,
    waiter_id       UUID REFERENCES users(user_id) ON DELETE SET NULL,
    customer_id     UUID REFERENCES users(user_id) ON DELETE SET NULL,
    order_number    TEXT NOT NULL,
    status          ORDER_STATUS NOT NULL DEFAULT 'draft',
    order_type      ORDER_TYPE NOT NULL,
    subtotal        NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (subtotal >= 0),
    tax_amount      NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (tax_amount >= 0),
    service_charge  NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (service_charge >= 0),
    discount_amount NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (discount_amount >= 0),
    total_amount    NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (order_id, created_at),
    CONSTRAINT orders_tenant_number_unique UNIQUE (tenant_id, order_number, created_at)
) PARTITION BY RANGE (created_at);
COMMENT ON TABLE orders IS 'Заказы. Partitioned by created_at (monthly). PK включает created_at — требование partitioning.';

CREATE TABLE IF NOT EXISTS order_items (
    order_item_id   BIGSERIAL PRIMARY KEY,
    order_id        UUID NOT NULL,
    order_created_at TIMESTAMPTZ NOT NULL,
    menu_item_id    UUID NOT NULL REFERENCES menu_items(menu_item_id) ON DELETE RESTRICT,
    item_name_snapshot TEXT NOT NULL,
    unit_price_snapshot NUMERIC(12, 2) NOT NULL CHECK (unit_price_snapshot >= 0),
    quantity        SMALLINT NOT NULL CHECK (quantity > 0),
    line_total      NUMERIC(14, 2) NOT NULL CHECK (line_total >= 0),
    special_requests TEXT,
    FOREIGN KEY (order_id, order_created_at)
        REFERENCES orders(order_id, created_at) ON DELETE CASCADE
);
COMMENT ON TABLE order_items IS 'Позиции заказа со snapshot цены и названия на момент заказа (даже если меню изменится).';

CREATE TABLE IF NOT EXISTS order_status_history (
    history_id      BIGSERIAL PRIMARY KEY,
    order_id        UUID NOT NULL,
    order_created_at TIMESTAMPTZ NOT NULL,
    old_status      ORDER_STATUS,
    new_status      ORDER_STATUS NOT NULL,
    changed_by      UUID REFERENCES users(user_id) ON DELETE SET NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    notes           TEXT,
    FOREIGN KEY (order_id, order_created_at)
        REFERENCES orders(order_id, created_at) ON DELETE CASCADE
);
COMMENT ON TABLE order_status_history IS 'История всех переходов статуса заказа. Заполняется триггером.';

CREATE TABLE IF NOT EXISTS payments (
    payment_id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    order_id        UUID NOT NULL,
    order_created_at TIMESTAMPTZ NOT NULL,
    method          PAYMENT_METHOD NOT NULL,
    status          PAYMENT_STATUS NOT NULL DEFAULT 'pending',
    amount          NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    tip_amount      NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (tip_amount >= 0),
    external_transaction_id TEXT,
    processed_by    UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (order_id, order_created_at)
        REFERENCES orders(order_id, created_at) ON DELETE RESTRICT
);
COMMENT ON TABLE payments IS 'Платежи по заказу. Заказ может иметь несколько платежей (split bill).';

CREATE TABLE IF NOT EXISTS refunds (
    refund_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_id      UUID NOT NULL REFERENCES payments(payment_id) ON DELETE RESTRICT,
    amount          NUMERIC(14, 2) NOT NULL CHECK (amount > 0),
    reason          TEXT NOT NULL,
    processed_by    UUID REFERENCES users(user_id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE refunds IS 'Возвраты средств по платежам.';

-- ----------------------------------------------------------------------------
-- Section 5. Customer experience
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS reservations (
    reservation_id  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    table_id        UUID NOT NULL REFERENCES restaurant_tables(table_id) ON DELETE CASCADE,
    customer_id     UUID REFERENCES users(user_id) ON DELETE SET NULL,
    guest_name      TEXT NOT NULL,
    guest_phone     TEXT NOT NULL,
    party_size      SMALLINT NOT NULL CHECK (party_size > 0),
    reserved_period TSTZRANGE NOT NULL,
    status          RESERVATION_STATUS NOT NULL DEFAULT 'pending',
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT reservations_period_valid CHECK (NOT isempty(reserved_period) AND lower(reserved_period) < upper(reserved_period)),
    -- EXCLUDE предотвращает пересечение активных бронирований на одном столе.
    -- Отменённые/no-show — не участвуют (через WHERE).
    CONSTRAINT reservations_no_overlap EXCLUDE USING gist (
        table_id WITH =,
        reserved_period WITH &&
    ) WHERE (status IN ('pending', 'confirmed', 'seated'))
);
COMMENT ON TABLE reservations IS 'Бронирования столов. EXCLUDE USING gist гарантирует отсутствие пересечений — защита на уровне БД.';

CREATE TABLE IF NOT EXISTS loyalty_accounts (
    loyalty_account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    customer_id     UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    points_balance  INTEGER NOT NULL DEFAULT 0 CHECK (points_balance >= 0),
    tier            TEXT NOT NULL DEFAULT 'bronze'
        CHECK (tier IN ('bronze', 'silver', 'gold', 'platinum')),
    lifetime_spent  NUMERIC(14, 2) NOT NULL DEFAULT 0 CHECK (lifetime_spent >= 0),
    enrolled_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT loyalty_tenant_customer_unique UNIQUE (tenant_id, customer_id)
);
COMMENT ON TABLE loyalty_accounts IS 'Счета программы лояльности: один customer может быть в разных tenant одновременно.';

CREATE TABLE IF NOT EXISTS loyalty_transactions (
    loyalty_transaction_id BIGSERIAL PRIMARY KEY,
    loyalty_account_id UUID NOT NULL REFERENCES loyalty_accounts(loyalty_account_id) ON DELETE CASCADE,
    transaction_type LOYALTY_TRANSACTION_TYPE NOT NULL,
    points_delta    INTEGER NOT NULL,
    order_id        UUID,
    order_created_at TIMESTAMPTZ,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (order_id, order_created_at)
        REFERENCES orders(order_id, created_at) ON DELETE SET NULL,
    CONSTRAINT loyalty_delta_sign CHECK (
        (transaction_type = 'earn' AND points_delta > 0)
        OR (transaction_type = 'redeem' AND points_delta < 0)
        OR (transaction_type = 'expire' AND points_delta < 0)
        OR (transaction_type = 'adjustment' AND points_delta <> 0)
    )
);
COMMENT ON TABLE loyalty_transactions IS 'Движения баллов лояльности: earn/redeem/expire/adjustment.';

CREATE TABLE IF NOT EXISTS reviews (
    review_id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       UUID NOT NULL REFERENCES tenants(tenant_id) ON DELETE CASCADE,
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    order_id        UUID,
    order_created_at TIMESTAMPTZ,
    customer_id     UUID REFERENCES users(user_id) ON DELETE SET NULL,
    rating          SMALLINT NOT NULL CHECK (rating BETWEEN 1 AND 5),
    comment         TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (order_id, order_created_at)
        REFERENCES orders(order_id, created_at) ON DELETE SET NULL
);
COMMENT ON TABLE reviews IS 'Отзывы клиентов на филиал/заказ.';

-- ----------------------------------------------------------------------------
-- Section 6. Operations & Audit
-- ----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS shifts (
    shift_id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    branch_id       UUID NOT NULL REFERENCES branches(branch_id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    clock_in        TIMESTAMPTZ NOT NULL,
    clock_out       TIMESTAMPTZ,
    notes           TEXT,
    CONSTRAINT shifts_period CHECK (clock_out IS NULL OR clock_out > clock_in)
);
COMMENT ON TABLE shifts IS 'Смены персонала: clock_in / clock_out для учёта рабочего времени и расчёта зарплаты.';

CREATE TABLE IF NOT EXISTS audit_log (
    audit_id        BIGSERIAL PRIMARY KEY,
    table_name      TEXT NOT NULL,
    row_pk          TEXT NOT NULL,
    operation       AUDIT_OPERATION NOT NULL,
    old_data        JSONB,
    new_data        JSONB,
    changed_by      UUID REFERENCES users(user_id) ON DELETE SET NULL,
    changed_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE audit_log IS 'Универсальный журнал изменений. Заполняется generic trigger trg_audit_all_changes через TG_TABLE_NAME и row_to_json.';

CREATE TABLE IF NOT EXISTS notifications (
    notification_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
    channel         NOTIFICATION_CHANNEL NOT NULL,
    subject         TEXT,
    body            TEXT NOT NULL,
    payload         JSONB NOT NULL DEFAULT '{}'::JSONB,
    sent_at         TIMESTAMPTZ,
    read_at         TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
COMMENT ON TABLE notifications IS 'Очередь исходящих уведомлений клиентам и персоналу.';
