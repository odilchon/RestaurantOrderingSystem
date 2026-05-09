"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState } from "react";
import { apiGet, apiPost, qs } from "@/lib/api";
import { useApp } from "@/lib/context";
import { useAsync, useDebounced } from "@/lib/hooks";
import { useToast } from "@/lib/toast";
import { useConfirm } from "@/components/confirm";
import { formatCurrency, formatDate } from "@/lib/format";
import {
  Button,
  Chip,
  EmptyState,
  ErrorBanner,
  Panel,
  SkeletonRows,
  StatusBadge,
} from "@/components/ui";
import { BranchSelector } from "@/components/filters";

type OrderRow = {
  order_id: string;
  created_at: string;
  branch_id: string;
  branch_name: string | null;
  table_id: string | null;
  table_number: string | null;
  waiter_name: string | null;
  order_number: string;
  status: string;
  order_type: string;
  items_count: number;
  total_amount: number;
};

const STATUSES = ["pending", "preparing", "ready", "served", "completed", "cancelled"];
const ORDER_TYPES = ["dine_in", "takeaway", "delivery"];

const CLOSABLE = new Set(["pending", "preparing", "ready", "served"]);
const CANCELLABLE = new Set(["pending", "preparing"]);

export default function OrdersPage() {
  const router = useRouter();
  const toast = useToast();
  const { branchId } = useApp();
  const { confirm, Dialog } = useConfirm();

  const [statusFilter, setStatusFilter] = useState<string | null>(null);
  const [typeFilter, setTypeFilter] = useState<string | null>(null);
  const [q, setQ] = useState("");
  const debouncedQ = useDebounced(q, 250);
  const [dateFrom, setDateFrom] = useState("");
  const [dateTo, setDateTo] = useState("");
  const [busyId, setBusyId] = useState<string | null>(null);

  const orders = useAsync<OrderRow[]>(
    () =>
      apiGet(
        `/orders/${qs({
          limit: 100,
          status: statusFilter,
          order_type: typeFilter,
          branch_id: branchId,
          q: debouncedQ,
          date_from: dateFrom || undefined,
          date_to: dateTo || undefined,
        })}`,
      ),
    [statusFilter, typeFilter, branchId, debouncedQ, dateFrom, dateTo],
  );

  async function close(r: OrderRow) {
    const ok = await confirm({
      title: `Close order ${r.order_number}?`,
      message: `Total: ${formatCurrency(r.total_amount)}. This will capture a cash payment.`,
      confirmLabel: "Close",
    });
    if (!ok) return;
    setBusyId(r.order_id);
    try {
      await apiPost(`/orders/${r.order_id}/close`, {
        method: "cash",
        amount: r.total_amount,
        tip: 0,
      });
      toast.success(`Order ${r.order_number} closed`);
      orders.reload();
    } catch (e: any) {
      toast.error(e?.message || "Failed to close order");
    } finally {
      setBusyId(null);
    }
  }

  async function cancel(r: OrderRow) {
    const reason = window.prompt(`Cancel order ${r.order_number}?  Reason:`);
    if (!reason) return;
    setBusyId(r.order_id);
    try {
      await apiPost(`/orders/${r.order_id}/cancel`, { reason });
      toast.success(`Order ${r.order_number} cancelled; stock restored`);
      orders.reload();
    } catch (e: any) {
      toast.error(e?.message || "Failed to cancel order");
    } finally {
      setBusyId(null);
    }
  }

  const rows = orders.data ?? [];

  return (
    <div className="space-y-5">
      <Dialog />
      <div className="flex flex-wrap justify-between items-center gap-3">
        <h1 className="text-2xl font-bold">Orders</h1>
        <div className="flex items-center gap-2">
          <BranchSelector />
          <Link href="/orders/new">
            <Button>+ New order</Button>
          </Link>
        </div>
      </div>

      {/* Filters bar */}
      <Panel>
        <div className="grid grid-cols-1 md:grid-cols-4 gap-3">
          <input
            className="bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-2 text-sm"
            placeholder="Search by order # …"
            value={q}
            onChange={(e) => setQ(e.target.value)}
          />
          <input
            type="date"
            className="bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-2 text-sm"
            value={dateFrom}
            onChange={(e) => setDateFrom(e.target.value)}
          />
          <input
            type="date"
            className="bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-2 text-sm"
            value={dateTo}
            onChange={(e) => setDateTo(e.target.value)}
          />
          <button
            onClick={() => {
              setStatusFilter(null);
              setTypeFilter(null);
              setQ("");
              setDateFrom("");
              setDateTo("");
            }}
            className="muted text-xs hover:text-brand-500 text-left"
          >
            ✕ Clear filters
          </button>
        </div>
        <div className="flex flex-wrap gap-1.5 mt-3">
          <Chip active={statusFilter === null} onClick={() => setStatusFilter(null)}>
            All statuses
          </Chip>
          {STATUSES.map((s) => (
            <Chip
              key={s}
              active={statusFilter === s}
              onClick={() => setStatusFilter(statusFilter === s ? null : s)}
            >
              {s}
            </Chip>
          ))}
        </div>
        <div className="flex flex-wrap gap-1.5 mt-2">
          <Chip active={typeFilter === null} onClick={() => setTypeFilter(null)}>
            Any type
          </Chip>
          {ORDER_TYPES.map((t) => (
            <Chip
              key={t}
              active={typeFilter === t}
              onClick={() => setTypeFilter(typeFilter === t ? null : t)}
            >
              {t}
            </Chip>
          ))}
        </div>
      </Panel>

      {orders.error && <ErrorBanner message={orders.error} onRetry={orders.reload} />}

      {orders.loading ? (
        <Panel>
          <SkeletonRows rows={6} cols={7} />
        </Panel>
      ) : rows.length === 0 ? (
        <EmptyState
          title="No orders match these filters"
          action={
            <Link href="/orders/new">
              <Button>Create first order</Button>
            </Link>
          }
        />
      ) : (
        <Panel className="overflow-x-auto p-0">
          <table className="w-full text-sm">
            <thead className="muted bg-[var(--bg)]">
              <tr className="[&>th]:text-left [&>th]:py-2 [&>th]:px-3 [&>th]:font-medium">
                <th>#</th>
                <th>Created</th>
                <th>Branch</th>
                <th>Table</th>
                <th>Waiter</th>
                <th>Type</th>
                <th>Items</th>
                <th>Status</th>
                <th className="text-right">Total</th>
                <th className="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((r) => (
                <tr
                  key={r.order_id}
                  className="border-t border-[var(--border)] hover:bg-[var(--bg)] cursor-pointer"
                  onClick={(e) => {
                    if ((e.target as HTMLElement).closest("button")) return;
                    router.push(`/orders/${r.order_id}`);
                  }}
                >
                  <td className="py-2 px-3 font-mono text-xs">{r.order_number}</td>
                  <td className="py-2 px-3 muted text-xs">{formatDate(r.created_at)}</td>
                  <td className="py-2 px-3 text-xs">{r.branch_name || "—"}</td>
                  <td className="py-2 px-3 text-xs">
                    {r.order_type === "dine_in" ? r.table_number || "—" : "—"}
                  </td>
                  <td className="py-2 px-3 text-xs">{r.waiter_name || "—"}</td>
                  <td className="py-2 px-3 text-xs">{r.order_type}</td>
                  <td className="py-2 px-3 text-xs">{r.items_count}</td>
                  <td className="py-2 px-3">
                    <StatusBadge status={r.status} />
                  </td>
                  <td className="py-2 px-3 text-right font-medium">
                    {formatCurrency(r.total_amount)}
                  </td>
                  <td className="py-2 px-3 text-right space-x-1 whitespace-nowrap">
                    {CLOSABLE.has(r.status) && (
                      <Button
                        size="sm"
                        variant="secondary"
                        disabled={busyId === r.order_id}
                        onClick={() => close(r)}
                      >
                        Close
                      </Button>
                    )}
                    {CANCELLABLE.has(r.status) && (
                      <Button
                        size="sm"
                        variant="danger"
                        disabled={busyId === r.order_id}
                        onClick={() => cancel(r)}
                      >
                        Cancel
                      </Button>
                    )}
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
