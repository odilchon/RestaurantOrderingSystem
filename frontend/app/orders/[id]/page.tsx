"use client";
import Link from "next/link";
import { useParams } from "next/navigation";
import { apiGet } from "@/lib/api";
import { useAsync } from "@/lib/hooks";
import { formatCurrency, formatDate } from "@/lib/format";
import {
  Button,
  ErrorBanner,
  Panel,
  SkeletonRows,
  StatusBadge,
} from "@/components/ui";

type OrderItem = {
  order_item_id: number;
  menu_item_id: string;
  name: string;
  quantity: number;
  unit_price: string;
  line_total: string;
  special_requests: string | null;
};

type StatusHistory = {
  old_status: string | null;
  new_status: string;
  changed_at: string;
  notes: string | null;
};

type Payment = {
  payment_id: string;
  method: string;
  status: string;
  amount: string;
  tip_amount: string;
  created_at: string;
};

type OrderDetails = {
  order_id: string;
  order_number: string;
  created_at: string;
  status: string;
  order_type: string;
  branch_name: string | null;
  table_number: string | null;
  waiter_name: string | null;
  customer_name: string | null;
  notes: string | null;
  subtotal: string;
  tax_amount: string;
  service_charge: string;
  discount_amount: string;
  total_amount: string;
  amount_paid: string;
  items: OrderItem[];
  status_history: StatusHistory[];
  payments: Payment[];
};

export default function OrderDetailsPage() {
  const params = useParams<{ id: string }>();
  const { data, loading, error, reload } = useAsync<OrderDetails>(
    () => apiGet(`/orders/${params.id}`),
    [params.id],
  );

  if (loading) {
    return (
      <div className="space-y-4">
        <SkeletonRows rows={2} cols={3} />
      </div>
    );
  }
  if (error || !data) {
    return <ErrorBanner message={error ?? "Not found"} onRetry={reload} />;
  }

  return (
    <div className="space-y-5">
      <div className="flex items-center gap-3">
        <Link href="/orders">
          <Button variant="ghost" size="sm">← Back</Button>
        </Link>
        <h1 className="text-2xl font-bold">Order {data.order_number}</h1>
        <StatusBadge status={data.status} />
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <Info label="Branch" value={data.branch_name || "—"} />
        <Info
          label={data.order_type === "dine_in" ? "Table" : "Type"}
          value={data.order_type === "dine_in" ? data.table_number || "—" : data.order_type}
        />
        <Info label="Waiter" value={data.waiter_name || "—"} />
        <Info label="Customer" value={data.customer_name || "—"} />
        <Info label="Created" value={formatDate(data.created_at)} />
        <Info label="Total" value={formatCurrency(data.total_amount)} />
      </div>

      {data.notes && <Panel><div className="muted text-xs mb-1">Notes</div><div className="text-sm">{data.notes}</div></Panel>}

      {/* Items */}
      <Panel>
        <div className="text-sm font-medium mb-3">Items ({data.items.length})</div>
        <table className="w-full text-sm">
          <thead className="muted">
            <tr className="[&>th]:text-left [&>th]:py-1 [&>th]:font-medium">
              <th>Item</th>
              <th className="text-right">Qty</th>
              <th className="text-right">Unit</th>
              <th className="text-right">Total</th>
            </tr>
          </thead>
          <tbody>
            {data.items.map((i) => (
              <tr key={i.order_item_id} className="border-t border-[var(--border)]">
                <td className="py-1.5">
                  {i.name}
                  {i.special_requests && (
                    <div className="muted text-[10px] mt-0.5">"{i.special_requests}"</div>
                  )}
                </td>
                <td className="py-1.5 text-right">{i.quantity}</td>
                <td className="py-1.5 text-right muted">{formatCurrency(i.unit_price)}</td>
                <td className="py-1.5 text-right font-medium">{formatCurrency(i.line_total)}</td>
              </tr>
            ))}
          </tbody>
          <tfoot className="muted">
            <tr className="border-t border-[var(--border)]">
              <td colSpan={3} className="py-1 text-right">Subtotal</td>
              <td className="py-1 text-right">{formatCurrency(data.subtotal)}</td>
            </tr>
            <tr>
              <td colSpan={3} className="py-1 text-right">Tax</td>
              <td className="py-1 text-right">{formatCurrency(data.tax_amount)}</td>
            </tr>
            <tr>
              <td colSpan={3} className="py-1 text-right">Service</td>
              <td className="py-1 text-right">{formatCurrency(data.service_charge)}</td>
            </tr>
            {Number(data.discount_amount) !== 0 && (
              <tr>
                <td colSpan={3} className="py-1 text-right">Discount</td>
                <td className="py-1 text-right">−{formatCurrency(data.discount_amount)}</td>
              </tr>
            )}
            <tr className="border-t border-[var(--border)] text-brand-500 font-bold">
              <td colSpan={3} className="py-1.5 text-right">Total</td>
              <td className="py-1.5 text-right">{formatCurrency(data.total_amount)}</td>
            </tr>
          </tfoot>
        </table>
      </Panel>

      {/* Payments */}
      {data.payments.length > 0 && (
        <Panel>
          <div className="text-sm font-medium mb-3">Payments</div>
          <table className="w-full text-sm">
            <thead className="muted">
              <tr className="[&>th]:text-left [&>th]:py-1 [&>th]:font-medium">
                <th>When</th>
                <th>Method</th>
                <th>Status</th>
                <th className="text-right">Amount</th>
                <th className="text-right">Tip</th>
              </tr>
            </thead>
            <tbody>
              {data.payments.map((p) => (
                <tr key={p.payment_id} className="border-t border-[var(--border)]">
                  <td className="py-1.5 muted">{formatDate(p.created_at)}</td>
                  <td className="py-1.5">{p.method}</td>
                  <td className="py-1.5">{p.status}</td>
                  <td className="py-1.5 text-right">{formatCurrency(p.amount)}</td>
                  <td className="py-1.5 text-right muted">{formatCurrency(p.tip_amount)}</td>
                </tr>
              ))}
              <tr className="border-t border-[var(--border)] font-medium">
                <td colSpan={3} className="py-1 text-right muted">Paid</td>
                <td className="py-1 text-right">{formatCurrency(data.amount_paid)}</td>
                <td></td>
              </tr>
            </tbody>
          </table>
        </Panel>
      )}

      {/* History */}
      {data.status_history.length > 0 && (
        <Panel>
          <div className="text-sm font-medium mb-3">Status history</div>
          <ol className="space-y-2 text-sm">
            {data.status_history.map((h, i) => (
              <li key={i} className="flex items-center gap-2">
                <span className="muted text-xs w-32">{formatDate(h.changed_at)}</span>
                <StatusBadge status={h.new_status} />
                {h.old_status && <span className="muted text-xs">← {h.old_status}</span>}
                {h.notes && <span className="muted text-xs">· {h.notes}</span>}
              </li>
            ))}
          </ol>
        </Panel>
      )}
    </div>
  );
}

function Info({ label, value }: { label: string; value: string }) {
  return (
    <div className="panel p-3">
      <div className="muted text-[10px] uppercase tracking-wider">{label}</div>
      <div className="text-sm mt-0.5">{value}</div>
    </div>
  );
}
