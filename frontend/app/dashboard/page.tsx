"use client";
import { useMemo, useState } from "react";
import {
  Area,
  AreaChart,
  Bar,
  BarChart,
  Cell,
  CartesianGrid,
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
import { periodByKey, PeriodKey } from "@/lib/period";
import { formatCurrency, formatDateOnly, formatCompact } from "@/lib/format";
import { Panel, SkeletonRows, ErrorBanner, Chip } from "@/components/ui";
import { PeriodSelector, BranchSelector } from "@/components/filters";

type DailyRevenueRow = {
  branch_id: string;
  branch_name: string | null;
  revenue_date: string;
  orders_count: number;
  revenue_total: number;
  avg_check: number;
};

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
  name: string;
};

const COLORS = ["#ff6b3d", "#16161a", "#f0552a", "#ffc1ab", "#5b5b66", "#ff9c7c"];

export default function DashboardPage() {
  const { period, branchId } = useApp();
  const days = periodByKey(period).days;

  const [metric, setMetric] = useState<"revenue" | "units">("revenue");
  const [categoryId, setCategoryId] = useState<string | null>(null);

  const revenue = useAsync<DailyRevenueRow[]>(
    () => apiGet(`/reports/daily-revenue${qs({ days, branch_id: branchId })}`),
    [days, branchId],
  );
  const topItems = useAsync<TopItem[]>(
    () =>
      apiGet(
        `/reports/top-items${qs({
          days,
          branch_id: branchId,
          category_id: categoryId,
          metric,
        })}`,
      ),
    [days, branchId, categoryId, metric],
  );
  const orderTypes = useAsync<OrderTypeSplit[]>(
    () => apiGet(`/reports/order-types${qs({ days, branch_id: branchId })}`),
    [days, branchId],
  );
  const categories = useAsync<Category[]>(
    () => apiGet("/menu/categories"),
    [],
  );

  const rows = revenue.data ?? [];
  const totalRevenue = rows.reduce((s, r) => s + Number(r.revenue_total || 0), 0);
  const totalOrders = rows.reduce((s, r) => s + Number(r.orders_count || 0), 0);

  const daily = useMemo(() => {
    const by: Record<string, { date: string; revenue: number; orders: number }> = {};
    for (const r of rows) {
      (by[r.revenue_date] ||= {
        date: r.revenue_date,
        revenue: 0,
        orders: 0,
      }).revenue += Number(r.revenue_total);
      by[r.revenue_date].orders += Number(r.orders_count);
    }
    return Object.values(by).sort((a, b) => a.date.localeCompare(b.date));
  }, [rows]);

  const topAgg = useMemo(() => {
    const by: Record<string, { name: string; units: number; revenue: number }> = {};
    for (const t of topItems.data ?? []) {
      (by[t.menu_item_name] ||= {
        name: t.menu_item_name,
        units: 0,
        revenue: 0,
      }).units += Number(t.units_sold);
      by[t.menu_item_name].revenue += Number(t.revenue);
    }
    const arr = Object.values(by);
    return metric === "revenue"
      ? arr.sort((a, b) => b.revenue - a.revenue).slice(0, 10)
      : arr.sort((a, b) => b.units - a.units).slice(0, 10);
  }, [topItems.data, metric]);

  const relevantCategories = (categories.data ?? []).filter(
    (c) => c.name.length < 30,
  );

  return (
    <div className="space-y-6">
      <div className="flex flex-wrap justify-between items-center gap-3">
        <h1 className="text-2xl font-bold">Dashboard</h1>
        <div className="flex flex-wrap items-center gap-3">
          <BranchSelector />
          <PeriodSelector />
        </div>
      </div>

      {/* KPI cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <KPI
          label={`Revenue (${periodByKey(period).label.toLowerCase()})`}
          value={formatCurrency(totalRevenue)}
          loading={revenue.loading}
        />
        <KPI
          label="Orders"
          value={totalOrders.toLocaleString("ru-RU")}
          loading={revenue.loading}
        />
        <KPI
          label="Avg check"
          value={totalOrders ? formatCurrency(totalRevenue / totalOrders) : "—"}
          loading={revenue.loading}
        />
      </div>

      {revenue.error && <ErrorBanner message={revenue.error} onRetry={revenue.reload} />}

      {/* Daily revenue chart */}
      <Panel>
        <div className="flex items-center justify-between mb-2">
          <div>
            <div className="text-sm font-medium">Daily revenue</div>
            <div className="muted text-[11px]">Source: mv_daily_revenue_by_branch</div>
          </div>
        </div>
        {revenue.loading ? (
          <SkeletonRows rows={3} cols={6} />
        ) : daily.length === 0 ? (
          <div className="muted text-sm py-8 text-center">No data for this period.</div>
        ) : (
          <div style={{ width: "100%", height: 260 }}>
            <ResponsiveContainer>
              <AreaChart data={daily} margin={{ top: 10, right: 20, bottom: 0, left: 0 }}>
                <defs>
                  <linearGradient id="rev" x1="0" y1="0" x2="0" y2="1">
                    <stop offset="0%" stopColor="#ff6b3d" stopOpacity={0.5} />
                    <stop offset="100%" stopColor="#ff6b3d" stopOpacity={0} />
                  </linearGradient>
                </defs>
                <CartesianGrid strokeDasharray="3 3" stroke="#ece9e0" />
                <XAxis
                  dataKey="date"
                  stroke="#8a8a93"
                  fontSize={11}
                  tickFormatter={(d) => formatDateOnly(d)}
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
                  labelFormatter={(d: string) => formatDateOnly(d)}
                />
                <Legend wrapperStyle={{ fontSize: 12 }} />
                <Area
                  type="monotone"
                  dataKey="revenue"
                  stroke="#ff6b3d"
                  fill="url(#rev)"
                  name="Revenue"
                />
              </AreaChart>
            </ResponsiveContainer>
          </div>
        )}
      </Panel>

      {/* Top items */}
      <Panel>
        <div className="flex flex-wrap items-center justify-between gap-3 mb-3">
          <div>
            <div className="text-sm font-medium">Top menu items</div>
            <div className="muted text-[11px]">By {metric === "revenue" ? "revenue" : "units sold"}</div>
          </div>
          <div className="flex items-center gap-2 flex-wrap">
            <Chip active={metric === "revenue"} onClick={() => setMetric("revenue")}>
              By revenue
            </Chip>
            <Chip active={metric === "units"} onClick={() => setMetric("units")}>
              By units
            </Chip>
          </div>
        </div>
        <div className="flex gap-1.5 mb-3 overflow-x-auto pb-1">
          <Chip active={categoryId === null} onClick={() => setCategoryId(null)}>
            All categories
          </Chip>
          {relevantCategories.map((c) => (
            <Chip
              key={c.category_id}
              active={categoryId === c.category_id}
              onClick={() => setCategoryId(c.category_id)}
            >
              {c.name}
            </Chip>
          ))}
        </div>
        {topItems.loading ? (
          <SkeletonRows rows={4} cols={5} />
        ) : topAgg.length === 0 ? (
          <div className="muted text-sm py-8 text-center">No items sold in this period.</div>
        ) : (
          <div style={{ width: "100%", height: 300 }}>
            <ResponsiveContainer>
              <BarChart data={topAgg} margin={{ top: 10, right: 10, bottom: 50, left: 0 }}>
                <CartesianGrid strokeDasharray="3 3" stroke="#ece9e0" />
                <XAxis
                  dataKey="name"
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
                  formatter={(v: number) =>
                    metric === "revenue" ? formatCurrency(v) : v.toLocaleString("ru-RU")
                  }
                />
                <Bar
                  dataKey={metric === "revenue" ? "revenue" : "units"}
                  fill="#ff6b3d"
                  name={metric === "revenue" ? "Revenue" : "Units"}
                />
              </BarChart>
            </ResponsiveContainer>
          </div>
        )}
      </Panel>

      {/* Order type pie */}
      <Panel>
        <div className="text-sm font-medium mb-1">Order type split</div>
        <div className="muted text-[11px] mb-3">dine_in / takeaway / delivery</div>
        {orderTypes.loading ? (
          <SkeletonRows rows={2} cols={3} />
        ) : (orderTypes.data ?? []).length === 0 ? (
          <div className="muted text-sm py-8 text-center">No orders in this period.</div>
        ) : (
          <div style={{ width: "100%", height: 260 }}>
            <ResponsiveContainer>
              <PieChart>
                <Pie
                  data={orderTypes.data ?? []}
                  dataKey="revenue"
                  nameKey="order_type"
                  cx="50%"
                  cy="50%"
                  outerRadius={90}
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
    </div>
  );
}

function KPI({
  label,
  value,
  loading,
}: {
  label: string;
  value: string;
  loading?: boolean;
}) {
  return (
    <div className="panel p-4">
      <div className="muted text-xs">{label}</div>
      {loading ? (
        <div className="h-7 w-24 bg-[var(--border)] rounded animate-pulse mt-1" />
      ) : (
        <div className="text-2xl font-bold mt-1">{value}</div>
      )}
    </div>
  );
}
