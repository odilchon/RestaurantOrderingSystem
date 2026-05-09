-- ============================================================================
-- 11_roles_grants.sql
-- Database roles с гранулированными правами.
--
-- Иерархия:
--   app_readonly  — только SELECT (дашборды, отчёты).
--   app_waiter    — SELECT + INSERT заказов/payments, минимум.
--   app_manager   — + UPDATE меню, inventory, закрытие заказов.
--   app_admin     — все DML + BYPASSRLS (миграции, back-office).
--
-- Все роли — NOLOGIN (grouping roles). Реальные login-пользователи
-- создаются поверх них через GRANT <role> TO <login_user>.
-- ============================================================================

DO $$ BEGIN
    CREATE ROLE app_readonly NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE ROLE app_waiter NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE ROLE app_manager NOLOGIN;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE ROLE app_admin NOLOGIN BYPASSRLS;
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Используем inheritance: manager наследует waiter, waiter наследует readonly.
GRANT app_readonly TO app_waiter;
GRANT app_waiter   TO app_manager;

-- ----------------------------------------------------------------------------
-- Base grants: право коннектиться и видеть схему
-- ----------------------------------------------------------------------------
DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_readonly', current_database());
END $$;
GRANT USAGE ON SCHEMA public TO app_readonly;

-- ----------------------------------------------------------------------------
-- app_readonly: SELECT на всё
-- ----------------------------------------------------------------------------
GRANT SELECT ON ALL TABLES IN SCHEMA public TO app_readonly;
GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO app_readonly;

ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON TABLES TO app_readonly;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT SELECT ON SEQUENCES TO app_readonly;

-- ----------------------------------------------------------------------------
-- app_waiter: создание заказов и платежей
-- ----------------------------------------------------------------------------
GRANT INSERT, UPDATE ON
    orders,
    order_items,
    order_status_history,
    payments,
    reservations,
    notifications
TO app_waiter;

-- audit_log is append-only and written by triggers running as the calling user.
-- Every role that mutates tracked tables must be able to INSERT here.
GRANT INSERT ON audit_log TO app_waiter;

GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO app_waiter;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT USAGE ON SEQUENCES TO app_waiter;

-- ----------------------------------------------------------------------------
-- app_manager: управление меню, складом, закупками, возвратами
-- ----------------------------------------------------------------------------
GRANT INSERT, UPDATE, DELETE ON
    categories,
    menu_items,
    menu_item_translations,
    menu_item_prices,
    menu_item_branch_availability,
    menu_item_ingredients,
    ingredients,
    inventory,
    inventory_movements,
    suppliers,
    purchase_orders,
    purchase_order_items,
    branches,
    zones,
    restaurant_tables,
    refunds,
    shifts,
    loyalty_accounts,
    loyalty_transactions,
    reviews
TO app_manager;

-- ----------------------------------------------------------------------------
-- app_admin: полные права на всё в схеме + BYPASSRLS (задан при CREATE ROLE)
-- ----------------------------------------------------------------------------
GRANT ALL ON ALL TABLES IN SCHEMA public TO app_admin;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO app_admin;
GRANT ALL ON ALL FUNCTIONS IN SCHEMA public TO app_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON TABLES TO app_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON SEQUENCES TO app_admin;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT ALL ON FUNCTIONS TO app_admin;

COMMENT ON ROLE app_readonly IS 'Read-only доступ: отчёты, дашборды, BI-инструменты.';
COMMENT ON ROLE app_waiter   IS 'Официант: создание заказов, платежей, бронирований. Наследует app_readonly.';
COMMENT ON ROLE app_manager  IS 'Менеджер филиала: управление меню, складом, закупками. Наследует app_waiter.';
COMMENT ON ROLE app_admin    IS 'Back-office/миграции. BYPASSRLS — обходит tenant изоляцию.';

-- ----------------------------------------------------------------------------
-- Login user for the FastAPI pool.
--
-- Why a separate login role instead of connecting as ros_admin?
--   ros_admin is a superuser. Superusers bypass RLS unconditionally, so if
--   the application ever forgot to SET LOCAL ROLE, tenant isolation would
--   silently disappear. app_user is NOT a superuser and has NO table grants
--   of its own — it exists purely to hold credentials and SET LOCAL ROLE to
--   app_readonly/waiter/manager per request. If SET LOCAL ROLE is omitted,
--   queries fail with "permission denied" instead of leaking data.
--
-- Password comes from env (APP_DB_PASSWORD). A placeholder is used during
-- bootstrap; rotate immediately in any real deployment.
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    pw TEXT := COALESCE(NULLIF(current_setting('ros.app_db_password', true), ''), 'app_dev_password');
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
        EXECUTE format('CREATE ROLE app_user LOGIN PASSWORD %L', pw);
    END IF;
END $$;

-- app_user inherits nothing automatically: it must SET LOCAL ROLE explicitly.
-- We GRANT the three tenant-scoped roles to it so SET ROLE can switch into them.
GRANT app_readonly TO app_user;
GRANT app_waiter   TO app_user;
GRANT app_manager  TO app_user;

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO app_user', current_database());
END $$;
GRANT USAGE ON SCHEMA public TO app_user;

COMMENT ON ROLE app_user IS
    'Login role for the FastAPI pool. Non-superuser. Holds no direct table grants — '
    'each request must SET LOCAL ROLE to app_readonly/waiter/manager so RLS is enforced.';
