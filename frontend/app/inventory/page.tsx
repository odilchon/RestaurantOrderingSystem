"use client";
import { useMemo, useState } from "react";
import { apiGet, qs } from "@/lib/api";
import { useApp } from "@/lib/context";
import { useAsync, useDebounced } from "@/lib/hooks";
import { formatCurrency } from "@/lib/format";
import {
  Button,
  Chip,
  EmptyState,
  ErrorBanner,
  Panel,
  SkeletonRows,
} from "@/components/ui";
import { BranchSelector } from "@/components/filters";

type LowStockRow = {
  branch_id: string;
  branch_name: string;
  ingredient_id: string;
  ingredient_name: string;
  unit: string;
  quantity: number;
  reorder_level: number;
  shortfall: number;
};

export default function InventoryPage() {
  const { branchId } = useApp();
  const [search, setSearch] = useState("");
  const [lowOnly, setLowOnly] = useState(true);
  const debouncedSearch = useDebounced(search, 250);

  const stock = useAsync<LowStockRow[]>(
    () => apiGet(`/reports/low-stock${qs({ branch_id: branchId })}`),
    [branchId],
  );

  const rows = useMemo(() => {
    const data = stock.data ?? [];
    const q = debouncedSearch.trim().toLowerCase();
    return data.filter((r) => {
      if (lowOnly && r.shortfall <= 0) return false;
      if (q && !r.ingredient_name.toLowerCase().includes(q)) return false;
      return true;
    });
  }, [stock.data, debouncedSearch, lowOnly]);

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap justify-between items-center gap-3">
        <div>
          <h1 className="text-2xl font-bold">Inventory</h1>
          <p className="muted text-sm">
            Stock levels vs. reorder thresholds. Sourced from <code>v_low_stock</code>.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <BranchSelector />
          <Button variant="secondary" size="sm" onClick={stock.reload}>
            ↻ Refresh
          </Button>
        </div>
      </div>

      {/* Filters */}
      <Panel>
        <div className="flex flex-wrap items-center gap-3">
          <input
            className="flex-1 bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-2 text-sm min-w-[200px]"
            placeholder="Search ingredient…"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <Chip active={lowOnly} onClick={() => setLowOnly(!lowOnly)}>
            {lowOnly ? "✓ " : ""}Low stock only
          </Chip>
        </div>
      </Panel>

      {stock.error && <ErrorBanner message={stock.error} onRetry={stock.reload} />}

      {stock.loading ? (
        <Panel>
          <SkeletonRows rows={6} cols={6} />
        </Panel>
      ) : rows.length === 0 ? (
        <EmptyState
          title={lowOnly ? "No shortages 🎉" : "No ingredients match filters"}
          hint={lowOnly ? "All ingredients above reorder level." : undefined}
        />
      ) : (
        <Panel className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="muted bg-[var(--bg)]">
              <tr className="[&>th]:py-2 [&>th]:px-3 [&>th]:font-medium [&>th]:text-left">
                <th>Branch</th>
                <th>Ingredient</th>
                <th>Unit</th>
                <th className="text-right">Qty</th>
                <th className="text-right">Reorder</th>
                <th className="text-right">Shortfall</th>
                <th>Status</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr
                  key={r.branch_id + r.ingredient_id}
                  className="border-t border-[var(--border)]"
                >
                  <td className="py-2 px-3">{r.branch_name}</td>
                  <td className="py-2 px-3 font-medium">{r.ingredient_name}</td>
                  <td className="py-2 px-3 muted text-xs">{r.unit}</td>
                  <td className="py-2 px-3 text-right">
                    {Number(r.quantity).toFixed(2)}
                  </td>
                  <td className="py-2 px-3 text-right muted">
                    {Number(r.reorder_level).toFixed(2)}
                  </td>
                  <td className="py-2 px-3 text-right text-red-600 font-medium">
                    −{Number(r.shortfall).toFixed(2)}
                  </td>
                  <td className="py-2 px-3">
                    <span className="px-2 py-0.5 rounded border text-[10px] uppercase bg-red-600/20 text-red-300 border-red-500/50">
                      Low
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Panel>
      )}
    </div>
  );
}
