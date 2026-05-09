-- ============================================================================
-- 10_rls_policies.sql
-- Row-Level Security для multi-tenant изоляции.
--
-- Модель: приложение в начале транзакции устанавливает
--     SET LOCAL app.current_tenant_id = '<uuid>';
--     SET LOCAL app.current_user_id   = '<uuid>';
--     SET LOCAL app.current_role      = 'manager';
-- Policies проверяют current_setting('app.current_tenant_id') и режут строки
-- чужих tenant-ов. Роль app_admin (в 11_roles_grants) обходит RLS через BYPASSRLS.
--
-- Принцип защиты: даже при SQL injection или баге в приложении пользователь
-- одного tenant-а физически не может прочитать/изменить данные другого.
-- ============================================================================

-- Хелпер: безопасно читает current_setting, возвращает NULL если не установлен.
CREATE OR REPLACE FUNCTION app_current_tenant_id()
RETURNS UUID
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_tenant_id', TRUE), '')::UUID;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;
COMMENT ON FUNCTION app_current_tenant_id() IS 'Возвращает tenant_id текущей сессии из GUC app.current_tenant_id.';

CREATE OR REPLACE FUNCTION app_current_user_id()
RETURNS UUID
LANGUAGE plpgsql STABLE AS $$
BEGIN
    RETURN NULLIF(current_setting('app.current_user_id', TRUE), '')::UUID;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;
END;
$$;

-- ----------------------------------------------------------------------------
-- Утилита: одинаковая политика «видишь только свой tenant» для всех таблиц
-- с колонкой tenant_id. Для таблиц без tenant_id изоляция идёт косвенно
-- через FK (например, order_items → orders.tenant_id).
-- ----------------------------------------------------------------------------

-- tenants: пользователь видит только свой собственный tenant.
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenants FORCE ROW LEVEL SECURITY;
CREATE POLICY tenants_isolation ON tenants
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- branches
ALTER TABLE branches ENABLE ROW LEVEL SECURITY;
ALTER TABLE branches FORCE ROW LEVEL SECURITY;
CREATE POLICY branches_isolation ON branches
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- categories
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories FORCE ROW LEVEL SECURITY;
CREATE POLICY categories_isolation ON categories
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- menu_items
ALTER TABLE menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE menu_items FORCE ROW LEVEL SECURITY;
CREATE POLICY menu_items_isolation ON menu_items
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- ingredients
ALTER TABLE ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingredients FORCE ROW LEVEL SECURITY;
CREATE POLICY ingredients_isolation ON ingredients
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- suppliers
ALTER TABLE suppliers ENABLE ROW LEVEL SECURITY;
ALTER TABLE suppliers FORCE ROW LEVEL SECURITY;
CREATE POLICY suppliers_isolation ON suppliers
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- purchase_orders
ALTER TABLE purchase_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchase_orders FORCE ROW LEVEL SECURITY;
CREATE POLICY purchase_orders_isolation ON purchase_orders
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- orders
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders FORCE ROW LEVEL SECURITY;
CREATE POLICY orders_isolation ON orders
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- reservations
ALTER TABLE reservations ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations FORCE ROW LEVEL SECURITY;
CREATE POLICY reservations_isolation ON reservations
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- loyalty_accounts
ALTER TABLE loyalty_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE loyalty_accounts FORCE ROW LEVEL SECURITY;
CREATE POLICY loyalty_accounts_isolation ON loyalty_accounts
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- reviews
ALTER TABLE reviews ENABLE ROW LEVEL SECURITY;
ALTER TABLE reviews FORCE ROW LEVEL SECURITY;
CREATE POLICY reviews_isolation ON reviews
    USING (tenant_id = app_current_tenant_id())
    WITH CHECK (tenant_id = app_current_tenant_id());

-- ----------------------------------------------------------------------------
-- Таблицы без tenant_id — изоляция через JOIN в policy.
-- ----------------------------------------------------------------------------

-- zones: через branches.tenant_id
ALTER TABLE zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE zones FORCE ROW LEVEL SECURITY;
CREATE POLICY zones_isolation ON zones
    USING (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = zones.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = zones.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ));

-- restaurant_tables: через branches
ALTER TABLE restaurant_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE restaurant_tables FORCE ROW LEVEL SECURITY;
CREATE POLICY restaurant_tables_isolation ON restaurant_tables
    USING (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = restaurant_tables.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = restaurant_tables.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ));

-- inventory: через branches
ALTER TABLE inventory ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory FORCE ROW LEVEL SECURITY;
CREATE POLICY inventory_isolation ON inventory
    USING (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = inventory.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = inventory.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ));

-- inventory_movements: через branches
ALTER TABLE inventory_movements ENABLE ROW LEVEL SECURITY;
ALTER TABLE inventory_movements FORCE ROW LEVEL SECURITY;
CREATE POLICY inventory_movements_isolation ON inventory_movements
    USING (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = inventory_movements.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM branches b
        WHERE b.branch_id = inventory_movements.branch_id
          AND b.tenant_id = app_current_tenant_id()
    ));

-- order_items: через orders
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items FORCE ROW LEVEL SECURITY;
CREATE POLICY order_items_isolation ON order_items
    USING (EXISTS (
        SELECT 1 FROM orders o
        WHERE o.order_id = order_items.order_id
          AND o.created_at = order_items.order_created_at
          AND o.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM orders o
        WHERE o.order_id = order_items.order_id
          AND o.created_at = order_items.order_created_at
          AND o.tenant_id = app_current_tenant_id()
    ));

-- payments: через orders
ALTER TABLE payments ENABLE ROW LEVEL SECURITY;
ALTER TABLE payments FORCE ROW LEVEL SECURITY;
CREATE POLICY payments_isolation ON payments
    USING (EXISTS (
        SELECT 1 FROM orders o
        WHERE o.order_id = payments.order_id
          AND o.created_at = payments.order_created_at
          AND o.tenant_id = app_current_tenant_id()
    ))
    WITH CHECK (EXISTS (
        SELECT 1 FROM orders o
        WHERE o.order_id = payments.order_id
          AND o.created_at = payments.order_created_at
          AND o.tenant_id = app_current_tenant_id()
    ));

-- ----------------------------------------------------------------------------
-- users, sessions, user_roles, audit_log, notifications:
-- RLS НЕ включаем на этом уровне — user может жить в нескольких tenant,
-- изоляция применяется через отдельный auth-слой приложения и role grants.
-- (Раскрывается в docs/security.md.)
-- ----------------------------------------------------------------------------
