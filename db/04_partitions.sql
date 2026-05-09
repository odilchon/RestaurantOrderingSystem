-- ============================================================================
-- 04_partitions.sql
-- Monthly range partitions для таблицы orders.
--
-- Подход: DEFAULT partition + функция ensure_orders_partition(month_start)
-- которая создаёт недостающую партицию. Для seed и демо создаём сразу
-- партиции на 14 месяцев (12 назад + текущий + 1 вперёд), чтобы
-- EXPLAIN ANALYZE на seed данных показывал partition pruning.
-- ============================================================================

-- Функция: гарантирует существование партиции на месяц, содержащий заданную дату.
CREATE OR REPLACE FUNCTION ensure_orders_partition(p_month_start DATE)
RETURNS VOID AS $$
DECLARE
    v_start DATE := date_trunc('month', p_month_start)::date;
    v_end   DATE := (date_trunc('month', p_month_start) + INTERVAL '1 month')::date;
    v_name  TEXT := format('orders_%s', to_char(v_start, 'YYYY_MM'));
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = v_name AND n.nspname = current_schema()
    ) THEN
        EXECUTE format(
            'CREATE TABLE %I PARTITION OF orders FOR VALUES FROM (%L) TO (%L)',
            v_name, v_start, v_end
        );
    END IF;
END;
$$ LANGUAGE plpgsql;
COMMENT ON FUNCTION ensure_orders_partition(DATE) IS
    'Создаёт месячную партицию orders для указанной даты, если её ещё нет. Идемпотентна.';

-- DEFAULT партиция: ловит всё, что не попало в явные месяцы.
-- Нужна как safety net — без неё INSERT в неизвестный месяц упадёт.
CREATE TABLE IF NOT EXISTS orders_default PARTITION OF orders DEFAULT;
COMMENT ON TABLE orders_default IS 'Default partition orders — ловит строки вне явно созданных месяцев. Мониторить: строки здесь = забыли создать партицию.';

-- Создаём партиции на период seed-данных: 12 месяцев назад → +1 месяц вперёд.
-- После Neделя 3 будет cron-job (или pg_partman), который делает это автоматически.
DO $$
DECLARE
    v_month DATE := date_trunc('month', NOW() - INTERVAL '12 months')::date;
BEGIN
    FOR i IN 0..13 LOOP
        PERFORM ensure_orders_partition(v_month);
        v_month := (v_month + INTERVAL '1 month')::date;
    END LOOP;
END $$;
