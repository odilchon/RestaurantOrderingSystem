-- ============================================================================
-- 08_functions.sql
-- Stored procedures / функции бизнес-логики на PL/pgSQL.
--
-- Все функции пишут в audit_log через generic trigger (09_triggers.sql),
-- поэтому внутри себя явный аудит не дублируют.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- fn_calculate_order_total
-- Пересчитывает subtotal/tax/service/total из order_items.
-- Tax rate и service rate берутся из tenants.settings (JSONB).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_calculate_order_total(
    p_order_id UUID,
    p_order_created_at TIMESTAMPTZ
)
RETURNS NUMERIC AS $$
DECLARE
    v_subtotal    NUMERIC(14, 2) := 0;
    v_tax_rate    NUMERIC := 0;
    v_service_rate NUMERIC := 0;
    v_discount    NUMERIC(14, 2);
    v_tax         NUMERIC(14, 2);
    v_service     NUMERIC(14, 2);
    v_total       NUMERIC(14, 2);
    v_tenant_id   UUID;
BEGIN
    SELECT COALESCE(SUM(line_total), 0)
      INTO v_subtotal
      FROM order_items
     WHERE order_id = p_order_id
       AND order_created_at = p_order_created_at;

    SELECT o.tenant_id, o.discount_amount
      INTO v_tenant_id, v_discount
      FROM orders o
     WHERE o.order_id = p_order_id
       AND o.created_at = p_order_created_at;

    SELECT
        COALESCE((t.settings->>'tax_rate')::NUMERIC, 0.12),
        COALESCE((t.settings->>'service_rate')::NUMERIC, 0.10)
      INTO v_tax_rate, v_service_rate
      FROM tenants t
     WHERE t.tenant_id = v_tenant_id;

    v_tax     := ROUND(v_subtotal * v_tax_rate, 2);
    v_service := ROUND(v_subtotal * v_service_rate, 2);
    v_total   := v_subtotal + v_tax + v_service - COALESCE(v_discount, 0);

    UPDATE orders
       SET subtotal       = v_subtotal,
           tax_amount     = v_tax,
           service_charge = v_service,
           total_amount   = v_total,
           updated_at     = NOW()
     WHERE order_id = p_order_id
       AND created_at = p_order_created_at;

    RETURN v_total;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_calculate_order_total(UUID, TIMESTAMPTZ) IS
    'Пересчитывает subtotal/tax/service/total заказа из позиций. Rates из tenants.settings JSONB.';

-- ----------------------------------------------------------------------------
-- fn_check_low_stock
-- Возвращает ингредиенты в филиале с количеством ниже reorder_level.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_check_low_stock(p_branch_id UUID)
RETURNS TABLE (
    ingredient_id UUID,
    ingredient_name TEXT,
    unit TEXT,
    quantity NUMERIC,
    reorder_level NUMERIC,
    shortfall NUMERIC
) AS $$
    SELECT
        ing.ingredient_id,
        ing.name,
        ing.unit,
        i.quantity,
        ing.reorder_level,
        (ing.reorder_level - i.quantity) AS shortfall
    FROM inventory i
    JOIN ingredients ing ON ing.ingredient_id = i.ingredient_id
    WHERE i.branch_id = p_branch_id
      AND i.quantity < ing.reorder_level
      AND ing.reorder_level > 0
    ORDER BY shortfall DESC;
$$ LANGUAGE sql STABLE;
COMMENT ON FUNCTION fn_check_low_stock(UUID) IS
    'Возвращает ингредиенты ниже reorder_level в филиале. Для алёртов и автоматических закупок.';

-- ----------------------------------------------------------------------------
-- fn_place_order
-- Атомарная постановка заказа:
--   1) создаём order (status='pending');
--   2) для каждой позиции: проверяем menu_item доступен в branch;
--   3) списываем ингредиенты (inventory_movements + trigger обновляет inventory);
--   4) если какого-то ингредиента не хватает — RAISE, вся транзакция откатывается;
--   5) пересчитываем total.
-- Возвращает (order_id, created_at, total).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_place_order(
    p_tenant_id UUID,
    p_branch_id UUID,
    p_table_id UUID,
    p_waiter_id UUID,
    p_customer_id UUID,
    p_order_type ORDER_TYPE,
    p_items JSONB,  -- [{"menu_item_id": "...", "quantity": 2, "special_requests": "..."}]
    p_notes TEXT DEFAULT null
)
RETURNS TABLE (order_id UUID, order_created_at TIMESTAMPTZ, total NUMERIC) AS $$
DECLARE
    v_order_id UUID := gen_random_uuid();
    v_created_at TIMESTAMPTZ := NOW();
    v_order_number TEXT;
    v_item JSONB;
    v_menu_item_id UUID;
    v_quantity SMALLINT;
    v_unit_price NUMERIC(12, 2);
    v_item_name TEXT;
    v_line_total NUMERIC(14, 2);
    v_ing RECORD;
    v_current_stock NUMERIC(12, 3);
    v_total NUMERIC(14, 2);
BEGIN
    -- order_number: tenant-specific sequence (дата + short hash)
    v_order_number := to_char(v_created_at, 'YYYYMMDD') || '-' ||
                      upper(substr(encode(gen_random_bytes(3), 'hex'), 1, 6));

    PERFORM ensure_orders_partition(v_created_at::date);

    INSERT INTO orders (
        order_id, created_at, tenant_id, branch_id, table_id,
        waiter_id, customer_id, order_number, status, order_type, notes
    ) VALUES (
        v_order_id, v_created_at, p_tenant_id, p_branch_id, p_table_id,
        p_waiter_id, p_customer_id, v_order_number, 'pending', p_order_type, p_notes
    );

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
        v_menu_item_id := (v_item->>'menu_item_id')::UUID;
        v_quantity     := (v_item->>'quantity')::SMALLINT;

        SELECT
            mi.name,
            COALESCE(mba.price_override,
                     (SELECT p.price FROM menu_item_prices p
                       WHERE p.menu_item_id = mi.menu_item_id AND p.valid_to IS NULL
                       LIMIT 1),
                     mi.base_price)
          INTO v_item_name, v_unit_price
          FROM menu_items mi
          LEFT JOIN menu_item_branch_availability mba
                 ON mba.menu_item_id = mi.menu_item_id
                AND mba.branch_id = p_branch_id
         WHERE mi.menu_item_id = v_menu_item_id
           AND mi.tenant_id = p_tenant_id
           AND mi.is_active = TRUE
           AND COALESCE(mba.is_available, TRUE) = TRUE;

        IF v_unit_price IS NULL THEN
            RAISE EXCEPTION 'Menu item % not available in branch %', v_menu_item_id, p_branch_id
                USING ERRCODE = 'no_data_found';
        END IF;

        v_line_total := v_unit_price * v_quantity;

        INSERT INTO order_items (
            order_id, order_created_at, menu_item_id,
            item_name_snapshot, unit_price_snapshot, quantity, line_total, special_requests
        ) VALUES (
            v_order_id, v_created_at, v_menu_item_id,
            v_item_name, v_unit_price, v_quantity, v_line_total, v_item->>'special_requests'
        );

        -- Списываем ингредиенты
        FOR v_ing IN
            SELECT mii.ingredient_id, mii.quantity * v_quantity AS needed
              FROM menu_item_ingredients mii
             WHERE mii.menu_item_id = v_menu_item_id
        LOOP
            SELECT quantity INTO v_current_stock
              FROM inventory
             WHERE branch_id = p_branch_id
               AND ingredient_id = v_ing.ingredient_id
             FOR UPDATE;

            IF v_current_stock IS NULL OR v_current_stock < v_ing.needed THEN
                RAISE EXCEPTION 'Insufficient stock for ingredient % in branch % (have %, need %)',
                    v_ing.ingredient_id, p_branch_id,
                    COALESCE(v_current_stock, 0), v_ing.needed
                    USING ERRCODE = 'check_violation';
            END IF;

            INSERT INTO inventory_movements (
                branch_id, ingredient_id, movement_type, quantity_delta,
                reference_type, reference_id
            ) VALUES (
                p_branch_id, v_ing.ingredient_id, 'consumption', -v_ing.needed,
                'order', v_order_id::TEXT
            );

            UPDATE inventory
               SET quantity = quantity - v_ing.needed,
                   updated_at = NOW()
             WHERE branch_id = p_branch_id
               AND ingredient_id = v_ing.ingredient_id;
        END LOOP;
    END LOOP;

    v_total := fn_calculate_order_total(v_order_id, v_created_at);

    RETURN QUERY SELECT v_order_id, v_created_at, v_total;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_place_order IS
    'Атомарная постановка заказа: создаёт order, позиции, списывает ингредиенты со склада. RAISE при нехватке → полный rollback.';

-- ----------------------------------------------------------------------------
-- fn_cancel_order
-- Отмена заказа: возвращает ингредиенты на склад (compensating transaction),
-- меняет статус на 'cancelled'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_cancel_order(
    p_order_id UUID,
    p_order_created_at TIMESTAMPTZ,
    p_reason TEXT
)
RETURNS VOID AS $$
DECLARE
    v_branch_id UUID;
    v_status order_status;
    v_item RECORD;
    v_ing RECORD;
BEGIN
    SELECT branch_id, status
      INTO v_branch_id, v_status
      FROM orders
     WHERE order_id = p_order_id
       AND created_at = p_order_created_at
       FOR UPDATE;

    IF v_status IS NULL THEN
        RAISE EXCEPTION 'Order % not found', p_order_id USING ERRCODE = 'no_data_found';
    END IF;
    IF v_status IN ('completed', 'cancelled', 'refunded') THEN
        RAISE EXCEPTION 'Cannot cancel order in status %', v_status USING ERRCODE = 'check_violation';
    END IF;

    -- Возвращаем ингредиенты за каждую позицию (compensating transaction)
    FOR v_item IN
        SELECT menu_item_id, quantity
          FROM order_items
         WHERE order_id = p_order_id
           AND order_created_at = p_order_created_at
    LOOP
        FOR v_ing IN
            SELECT mii.ingredient_id, mii.quantity * v_item.quantity AS to_return
              FROM menu_item_ingredients mii
             WHERE mii.menu_item_id = v_item.menu_item_id
        LOOP
            INSERT INTO inventory_movements (
                branch_id, ingredient_id, movement_type, quantity_delta,
                reference_type, reference_id, notes
            ) VALUES (
                v_branch_id, v_ing.ingredient_id, 'return', v_ing.to_return,
                'order_cancellation', p_order_id::TEXT, p_reason
            );

            UPDATE inventory
               SET quantity = quantity + v_ing.to_return,
                   updated_at = NOW()
             WHERE branch_id = v_branch_id
               AND ingredient_id = v_ing.ingredient_id;
        END LOOP;
    END LOOP;

    UPDATE orders
       SET status = 'cancelled',
           notes = COALESCE(notes, '') || ' | cancel: ' || p_reason,
           updated_at = NOW()
     WHERE order_id = p_order_id
       AND created_at = p_order_created_at;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_cancel_order IS
    'Отмена заказа с возвратом ингредиентов на склад. Запрещена для completed/cancelled/refunded.';

-- ----------------------------------------------------------------------------
-- fn_close_order
-- Закрытие заказа: создаёт payment, начисляет лояльность, меняет статус.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_close_order(
    p_order_id UUID,
    p_order_created_at TIMESTAMPTZ,
    p_method PAYMENT_METHOD,
    p_amount NUMERIC,
    p_tip NUMERIC DEFAULT 0,
    p_processed_by UUID DEFAULT null
)
RETURNS UUID AS $$
DECLARE
    v_payment_id UUID := gen_random_uuid();
    v_customer_id UUID;
    v_tenant_id UUID;
    v_total NUMERIC(14, 2);
BEGIN
    SELECT customer_id, tenant_id, total_amount
      INTO v_customer_id, v_tenant_id, v_total
      FROM orders
     WHERE order_id = p_order_id
       AND created_at = p_order_created_at
       FOR UPDATE;

    IF v_total IS NULL THEN
        RAISE EXCEPTION 'Order % not found', p_order_id USING ERRCODE = 'no_data_found';
    END IF;
    IF p_amount < v_total THEN
        RAISE EXCEPTION 'Payment amount % less than order total %', p_amount, v_total
            USING ERRCODE = 'check_violation';
    END IF;

    INSERT INTO payments (
        payment_id, order_id, order_created_at, method, status,
        amount, tip_amount, processed_by
    ) VALUES (
        v_payment_id, p_order_id, p_order_created_at, p_method, 'captured',
        p_amount, p_tip, p_processed_by
    );

    UPDATE orders
       SET status = 'completed',
           updated_at = NOW()
     WHERE order_id = p_order_id
       AND created_at = p_order_created_at;

    IF v_customer_id IS NOT NULL THEN
        PERFORM fn_award_loyalty_points(v_customer_id, v_tenant_id, p_order_id, p_order_created_at);
    END IF;

    RETURN v_payment_id;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_close_order IS
    'Закрывает заказ: создаёт payment, меняет status→completed, начисляет баллы лояльности.';

-- ----------------------------------------------------------------------------
-- fn_award_loyalty_points
-- Начисляет баллы клиенту за заказ: 1 балл за каждые 100 сом, с tier-бонусом.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_award_loyalty_points(
    p_customer_id UUID,
    p_tenant_id UUID,
    p_order_id UUID,
    p_order_created_at TIMESTAMPTZ
)
RETURNS INTEGER AS $$
DECLARE
    v_account_id UUID;
    v_tier TEXT;
    v_total NUMERIC;
    v_points INTEGER;
    v_multiplier NUMERIC;
BEGIN
    SELECT la.loyalty_account_id, la.tier
      INTO v_account_id, v_tier
      FROM loyalty_accounts la
     WHERE la.customer_id = p_customer_id
       AND la.tenant_id = p_tenant_id
       FOR UPDATE;

    IF v_account_id IS NULL THEN
        INSERT INTO loyalty_accounts (tenant_id, customer_id)
        VALUES (p_tenant_id, p_customer_id)
        RETURNING loyalty_account_id, tier INTO v_account_id, v_tier;
    END IF;

    SELECT total_amount INTO v_total
      FROM orders
     WHERE order_id = p_order_id AND created_at = p_order_created_at;

    v_multiplier := CASE v_tier
        WHEN 'bronze'   THEN 1.0
        WHEN 'silver'   THEN 1.25
        WHEN 'gold'     THEN 1.5
        WHEN 'platinum' THEN 2.0
        ELSE 1.0 END;

    v_points := FLOOR(v_total / 100 * v_multiplier)::INTEGER;

    IF v_points > 0 THEN
        INSERT INTO loyalty_transactions (
            loyalty_account_id, transaction_type, points_delta,
            order_id, order_created_at
        ) VALUES (
            v_account_id, 'earn', v_points, p_order_id, p_order_created_at
        );

        UPDATE loyalty_accounts
           SET points_balance = points_balance + v_points,
               lifetime_spent = lifetime_spent + v_total
         WHERE loyalty_account_id = v_account_id;
    END IF;

    RETURN v_points;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_award_loyalty_points IS
    'Начисляет баллы лояльности с учётом tier multiplier. Создаёт loyalty_account если его ещё нет.';
