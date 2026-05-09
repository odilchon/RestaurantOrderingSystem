-- ============================================================================
-- 02_enums.sql
-- ENUM-типы для стабильных доменов. Используем ENUM там, где множество
-- значений фиксировано и меняется редко — это даёт хранилищу 4 байта
-- вместо TEXT и защиту от опечаток на уровне типа.
-- ============================================================================

-- Системные роли. tenant_owner/manager/waiter/chef/cashier — сотрудники
-- tenant'а; super_admin — платформенный уровень; customer — внешний клиент.
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM (
        'super_admin',
        'tenant_owner',
        'manager',
        'waiter',
        'chef',
        'cashier',
        'customer'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Жизненный цикл заказа. cancelled/refunded — терминальные ветки.
DO $$ BEGIN
    CREATE TYPE order_status AS ENUM (
        'draft',
        'pending',
        'confirmed',
        'preparing',
        'ready',
        'served',
        'completed',
        'cancelled',
        'refunded'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Канал заказа. Влияет на бизнес-логику (доставка требует адрес,
-- takeaway — время готовности, dine_in — стол).
DO $$ BEGIN
    CREATE TYPE order_type AS ENUM (
        'dine_in',
        'takeaway',
        'delivery'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Методы оплаты. Для КГ-рынка актуальны наличные + локальные кошельки.
DO $$ BEGIN
    CREATE TYPE payment_method AS ENUM (
        'cash',
        'card',
        'elsom',
        'mbank',
        'optima',
        'bank_transfer',
        'loyalty_points'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Статус платежа отдельно от статуса заказа: один заказ может иметь
-- несколько платежей (split bill, частичные возвраты).
DO $$ BEGIN
    CREATE TYPE payment_status AS ENUM (
        'pending',
        'authorized',
        'captured',
        'failed',
        'refunded',
        'partially_refunded'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Статус стола в зале. Используется для live-дашборда хостес.
DO $$ BEGIN
    CREATE TYPE table_status AS ENUM (
        'available',
        'occupied',
        'reserved',
        'dirty',
        'out_of_service'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Статус бронирования. no_show отдельно от cancelled — для аналитики
-- провалов загрузки зала.
DO $$ BEGIN
    CREATE TYPE reservation_status AS ENUM (
        'pending',
        'confirmed',
        'seated',
        'completed',
        'cancelled',
        'no_show'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Типы движений склада — event-sourcing стиль: не перезаписываем остаток,
-- а пишем движение, текущий остаток вычисляется через агрегат.
DO $$ BEGIN
    CREATE TYPE inventory_movement_type AS ENUM (
        'purchase',
        'consumption',
        'waste',
        'adjustment',
        'transfer_in',
        'transfer_out',
        'return'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Статус закупки у поставщика.
DO $$ BEGIN
    CREATE TYPE purchase_order_status AS ENUM (
        'draft',
        'submitted',
        'approved',
        'received',
        'cancelled'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Направление транзакции лояльности.
DO $$ BEGIN
    CREATE TYPE loyalty_transaction_type AS ENUM (
        'earn',
        'redeem',
        'expire',
        'adjustment'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Операция в audit_log — соответствует TG_OP в триггерах.
DO $$ BEGIN
    CREATE TYPE audit_operation AS ENUM ('INSERT', 'UPDATE', 'DELETE');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- Канал уведомлений.
DO $$ BEGIN
    CREATE TYPE notification_channel AS ENUM (
        'in_app',
        'sms',
        'email',
        'push',
        'telegram'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
