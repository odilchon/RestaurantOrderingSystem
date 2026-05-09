-- ============================================================================
-- 09_triggers.sql
-- Триггеры Restaurant Ordering System.
--
-- 1) trg_audit_* : generic audit trigger через TG_TABLE_NAME + row_to_json.
-- 2) trg_update_menu_item_search_vector : автообновление tsvector.
-- 3) trg_update_order_status_history : лог смены статуса заказа.
-- 4) trg_touch_updated_at : updated_at = NOW() на UPDATE.
-- 5) trg_inventory_movement_guard : defensive check на inventory_movements.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. GENERIC AUDIT TRIGGER
-- Одна функция покрывает все таблицы через TG_TABLE_NAME и row_to_json(OLD/NEW).
-- Особенность: PK каждой таблицы может называться по-разному, поэтому
-- используем общую стратегию — записываем row_to_json(OLD/NEW) полностью,
-- а row_pk хранит текстовое представление первого PK-столбца.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_audit_row_change()
RETURNS TRIGGER AS $$
DECLARE
    v_old JSONB := NULL;
    v_new JSONB := NULL;
    v_pk  TEXT;
    v_user UUID := app_current_user_id();
BEGIN
    IF TG_OP = 'DELETE' THEN
        v_old := to_jsonb(OLD);
        v_pk  := COALESCE(v_old->>'id', v_old->>(TG_TABLE_NAME || '_id'), v_old->>'order_id', '(unknown)');
    ELSIF TG_OP = 'UPDATE' THEN
        v_old := to_jsonb(OLD);
        v_new := to_jsonb(NEW);
        v_pk  := COALESCE(v_new->>'id', v_new->>(TG_TABLE_NAME || '_id'), v_new->>'order_id', '(unknown)');
    ELSIF TG_OP = 'INSERT' THEN
        v_new := to_jsonb(NEW);
        v_pk  := COALESCE(v_new->>'id', v_new->>(TG_TABLE_NAME || '_id'), v_new->>'order_id', '(unknown)');
    END IF;

    INSERT INTO audit_log (table_name, row_pk, operation, old_data, new_data, changed_by)
    VALUES (TG_TABLE_NAME, v_pk, TG_OP::audit_operation, v_old, v_new, v_user);

    RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION fn_audit_row_change() IS
    'Generic audit trigger: пишет в audit_log для любой таблицы через TG_TABLE_NAME и row_to_json. Одна функция на все.';

-- Подключаем к критичным таблицам
DO $$
DECLARE
    v_tbl TEXT;
    v_tables TEXT[] := ARRAY[
        'tenants', 'branches', 'users', 'menu_items', 'menu_item_prices',
        'ingredients', 'inventory', 'orders', 'payments', 'refunds',
        'purchase_orders', 'reservations', 'loyalty_accounts'
    ];
BEGIN
    FOREACH v_tbl IN ARRAY v_tables LOOP
        EXECUTE format(
            'DROP TRIGGER IF EXISTS trg_audit_%I ON %I', v_tbl, v_tbl
        );
        EXECUTE format(
            'CREATE TRIGGER trg_audit_%I
             AFTER INSERT OR UPDATE OR DELETE ON %I
             FOR EACH ROW EXECUTE FUNCTION fn_audit_row_change()',
            v_tbl, v_tbl
        );
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 2. FULL-TEXT SEARCH tsvector update
-- Комбинируем name + description + имя категории, с русским словарём.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_menu_items_search_vector_update()
RETURNS TRIGGER AS $$
DECLARE
    v_category_name TEXT;
BEGIN
    SELECT name INTO v_category_name FROM categories WHERE category_id = NEW.category_id;
    NEW.search_vector :=
        setweight(to_tsvector('simple', COALESCE(NEW.name, '')), 'A') ||
        setweight(to_tsvector('simple', COALESCE(v_category_name, '')), 'B') ||
        setweight(to_tsvector('simple', COALESCE(NEW.description, '')), 'C');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_menu_items_search_vector ON menu_items;
CREATE TRIGGER trg_menu_items_search_vector
BEFORE INSERT OR UPDATE OF name, description, category_id ON menu_items
FOR EACH ROW EXECUTE FUNCTION fn_menu_items_search_vector_update();
COMMENT ON TRIGGER trg_menu_items_search_vector ON menu_items IS
    'Автообновление tsvector с весами A (name) > B (category) > C (description).';

-- ----------------------------------------------------------------------------
-- 3. ORDER STATUS HISTORY
-- При смене статуса записывает предыдущий/новый в order_status_history.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_order_status_history()
RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'INSERT' OR NEW.status IS DISTINCT FROM OLD.status THEN
        INSERT INTO order_status_history (
            order_id, order_created_at, old_status, new_status, changed_by
        ) VALUES (
            NEW.order_id,
            NEW.created_at,
            CASE WHEN TG_OP = 'INSERT' THEN NULL ELSE OLD.status END,
            NEW.status,
            app_current_user_id()
        );
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_orders_status_history ON orders;
CREATE TRIGGER trg_orders_status_history
AFTER INSERT OR UPDATE OF status ON orders
FOR EACH ROW EXECUTE FUNCTION fn_order_status_history();

-- ----------------------------------------------------------------------------
-- 4. TOUCH updated_at
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_touch_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DO $$
DECLARE
    v_tbl TEXT;
    v_tables TEXT[] := ARRAY[
        'tenants', 'users', 'branches', 'restaurant_tables', 'menu_items',
        'orders', 'purchase_orders', 'reservations'
    ];
BEGIN
    FOREACH v_tbl IN ARRAY v_tables LOOP
        EXECUTE format('DROP TRIGGER IF EXISTS trg_touch_updated_at_%I ON %I', v_tbl, v_tbl);
        EXECUTE format(
            'CREATE TRIGGER trg_touch_updated_at_%I
             BEFORE UPDATE ON %I
             FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at()',
            v_tbl, v_tbl
        );
    END LOOP;
END $$;

-- ----------------------------------------------------------------------------
-- 5. INVENTORY MOVEMENT GUARD
-- Дополнительная защита: нельзя через DELETE откатывать движения склада —
-- они append-only (event source). Единственный способ исправить — новое
-- движение типа 'adjustment'.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_inventory_movement_guard()
RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'inventory_movements is append-only: use adjustment movement instead of %', TG_OP
        USING ERRCODE = 'check_violation';
    RETURN NULL;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_inventory_movements_append_only ON inventory_movements;
CREATE TRIGGER trg_inventory_movements_append_only
BEFORE UPDATE OR DELETE ON inventory_movements
FOR EACH ROW EXECUTE FUNCTION fn_inventory_movement_guard();
COMMENT ON TRIGGER trg_inventory_movements_append_only ON inventory_movements IS
    'Запрещает UPDATE/DELETE — склад должен корректироваться через новое движение adjustment.';
