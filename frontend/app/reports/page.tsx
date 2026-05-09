"use client";
import {
  Bar,
  BarChart,
  CartesianGrid,
  Cell,
  Legend,
  Pie,
  PieChart,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";
import { apiGet, qs } from "@/lib/api";
import { useApp } from "@/lib/context";
import { useAsync } from "@/lib/hooks";
import { periodByKey } from "@/lib/period";
import { formatCurrency, formatCompact } from "@/lib/format";
import { Button, ErrorBanner, Panel, SkeletonRows } from "@/components/ui";
import { BranchSelector, PeriodSelector } from "@/components/filters";

type TopItem = {
  menu_item_id: string;
  branch_id: string;
  menu_item_name: string;
  category_name: string | null;
  units_sold: number;
  revenue: number;
  revenue_rank: number;
};

type OrderTypeSplit = {
  order_type: string;
  orders_count: number;
  revenue: number;
};

type Category = {
  category_id: string;
  category_name: string;
  units_sold: number;
  revenue: number;
};

const COLORS = ["#ff6b3d", "#0ea5e9", "#22c55e", "#a855f7", "#ef4444", "#eab308"];

function toCSV(rows: Record<string, unknown>[]): string {
  if (!rows.length) return "";
  const headers = Object.keys(rows[0]);
  const esc = (v: unknown) => {
    const s = v == null ? "" : String(v);
    return s.includes(",") || s.includes('"') || s.includes("\n")
      ? `"${s.replace(/"/g, '""')}"`
      : s;
  };
  return [
    headers.join(","),
    ...rows.map((r) => headers.map((h) => esc(r[h])).join(",")),
  ].join("\n");
}

function downloadCSV(filename: string, csv: string) {
  const blob = new Blob([csv], { type: "text/csv;charset=utf-8" });
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = filename;
  a.click();
  URL.revokeObjectURL(url);
}

export default function ReportsPage() {
  const { period, branchId } = useApp();
  const days = periodByKey(period).days;

  const top = useAsync<TopItem[]>(
    () =>
      apiGet(
        `/reports/top-items${qs({ days, branch_id: branchId, metric: "revenue", limit: 30 })}`,
      ),
    [days, branchId],
  );
  const categories = useAsync<Category[]>(
    () => apiGet(`/reports/category-breakdown${qs({ days, branch_id: branchId })}`),
    [days, branchId],
  );
  const orderTypes = useAsync<OrderTypeSplit[]>(
    () => apiGet(`/reports/order-types${qs({ days, branch_id: branchId })}`),
    [days, branchId],
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap justify-between items-center gap-3">
        <h1 className="text-2xl font-bold">Reports</h1>
        <div className="flex flex-wrap items-center gap-3">
          <BranchSelector />
          <PeriodSelector />
        </div>
      </div>

      {/* Category revenue */}
      <Panel>
        <div className="flex justify-between items-center mb-3">
          <div>
            <div className="text-sm font-medium">Revenue by category</div>
            <div className="muted text-[11px]">
              Period: {periodByKey(period).label.toLowerCase()}
            </div>
          </div>
          {categories.data && categories.data.length > 0 && (
            <Button
              variant="secondary"
              size="sm"
              onClick={() =>
                downloadCSV(
                  "category-breakdown.csv",
                  toCSV(categories.data as unknown as Record<string, unknown>[]),
                )
              }
            >
              ⬇ CSV
            </Button>
          )}
        </div>
        {categories.error && <ErrorBanner message={categories.error} onRetry={categories.reload} />}
        {categories.loading ? (
          <SkeletonRows rows={3} cols={5} />
        ) : (categories.data ?? []).length === 0 ? (
          <div className="muted text-sm py-6 text-center">No sales in this period.</div>
        ) : (
          <div style={{ width: "100%", height: 280 }}>
            <ResponsiveContainer>
              <BarChart
                data={categories.data ?? []}
                margin={{ top: 10, right: 10, bottom: 40, left: 0 }}
              >
                <CartesianGrid strokeDasharray="3 3" stroke="#ece9e0" />
                <XAxis
                  dataKey="category_name"
                  stroke="#8a8a93"
                  fontSize={10}
                  interval={0}
                  angle={-20}
                  textAnchor="end"
                />
                <YAxis stroke="#8a8a93" fontSize={11} tickFormatter={formatCompact} />
                <Tooltip
                  contentStyle={{
                    background: "#ffffff",
                    border: "1px solid #ece9e0",
                    borderRadius: 12,
                    fontSize: 12,
                  }}
                  formatter={(v: number) => formatCurrency(v)}
                />
                <Bar dataKey="revenue" fill="#ff6b3d" />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </Panel>

      {/* Order types pie */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-5">
        <Panel>
          <div className="text-sm font-medium mb-1">Order type split</div>
          <div className="muted text-[11px] mb-3">dine_in / takeaway / delivery</div>
          {orderTypes.loading ? (
            <SkeletonRows rows={2} cols={3} />
          ) : (orderTypes.data ?? []).length === 0 ? (
            <div className="muted text-sm py-6 text-center">No orders.</div>
          ) : (
            <div style={{ width: "100%", height: 240 }}>
              <ResponsiveContainer>
                <PieChart>
                  <Pie
                    data={orderTypes.data ?? []}
                    dataKey="revenue"
                    nameKey="order_type"
                    cx="50%"
                    cy="50%"
                    outerRadius={80}
                    label={(d: any) =>
                      `${d.order_type}: ${formatCompact(d.revenue as number)}`
                    }
                  >
                    {(orderTypes.data ?? []).map((_, i) => (
                      <Cell key={i} fill={COLORS[i % COLORS.length]} />
                    ))}
                  </Pie>
                  <Tooltip
                    contentStyle={{
                      background: "#ffffff",
                      border: "1px solid #ece9e0",
                      borderRadius: 12,
                      fontSize: 12,
                    }}
                    formatter={(v: number) => formatCurrency(v)}
                  />
                  <Legend wrapperStyle={{ fontSize: 12 }} />
                </PieChart>
              </ResponsiveContainer>
            </div>
          )}
        </Panel>

        <Panel>
          <div className="text-sm font-medium mb-1">Top menu items (by revenue)</div>
          <div className="muted text-[11px] mb-3">mv_top_menu_items_30d joined live</div>
          {top.loading ? (
            <SkeletonRows rows={5} cols={3} />
          ) : (top.data ?? []).length === 0 ? (
            <div className="muted text-sm py-6 text-center">No items sold.</div>
          ) : (
            <table className="w-full text-sm">
              <thead className="muted">
                <tr className="[&>th]:text-left [&>th]:py-1 [&>th]:font-medium">
                  <th>Rank</th>
                  <th>Item</th>
                  <th className="text-right">Units</th>
                  <th className="text-right">Revenue</th>
                </tr>
              </thead>
              <tbody>
                {(top.data ?? []).slice(0, 15).map((r, i) => (
                  <tr key={i} className="border-t border-[var(--border)]">
                    <td className="py-1 muted">#{r.revenue_rank}</td>
                    <td className="py-1">{r.menu_item_name}</td>
                    <td className="py-1 text-right">{r.units_sold}</td>
                    <td className="py-1 text-right">{formatCurrency(r.revenue)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </Panel>
      </div>

    </div>
  );
}
