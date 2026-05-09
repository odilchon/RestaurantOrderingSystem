"use client";
import { useEffect, useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { apiGet, apiPost, qs } from "@/lib/api";
import { useApp } from "@/lib/context";
import { useAsync, useDebounced } from "@/lib/hooks";
import { useToast } from "@/lib/toast";
import { formatCurrency } from "@/lib/format";
import {
  Button,
  Chip,
  ErrorBanner,
  Panel,
  SkeletonRows,
} from "@/components/ui";

type Branch = { branch_id: string; name: string; address: string | null; city: string | null };
type Table = {
  table_id: string;
  branch_id: string;
  table_number: string;
  seats: number;
  zone_name: string | null;
  status: string;
  is_occupied: boolean;
};
type Category = { category_id: string; name: string; items_count: number };
type MenuItem = {
  menu_item_id: string;
  category_id: string;
  category_name: string;
  name: string;
  current_price: number;
};

type CartRow = {
  menu_item_id: string;
  name: string;
  unit_price: number;
  quantity: number;
};

type OrderType = "dine_in" | "takeaway" | "delivery";

export default function NewOrderPage() {
  const router = useRouter();
  const toast = useToast();
  const { me } = useApp();

  // -------------------- state
  const [branchId, setBranchId] = useState<string>("");
  const [tableId, setTableId] = useState<string>("");
  const [orderType, setOrderType] = useState<OrderType>("dine_in");
  const [categoryId, setCategoryId] = useState<string | null>(null);
  const [search, setSearch] = useState("");
  const [cart, setCart] = useState<CartRow[]>([]);
  const [notes, setNotes] = useState("");
  const [busy, setBusy] = useState(false);

  const debouncedSearch = useDebounced(search, 250);

  // -------------------- fetches
  const branches = useAsync<Branch[]>(() => apiGet("/places/branches"), []);
  const categories = useAsync<Category[]>(() => apiGet("/menu/categories"), []);
  const tables = useAsync<Table[]>(
    () =>
      branchId
        ? apiGet(`/places/branches/${branchId}/tables`)
        : Promise.resolve([] as Table[]),
    [branchId],
  );
  const menu = useAsync<MenuItem[]>(
    () =>
      branchId
        ? apiGet(
            `/menu/${qs({
              branch_id: branchId,
              category_id: categoryId,
              search: debouncedSearch,
              sort: "category",
            })}`,
          )
        : Promise.resolve([] as MenuItem[]),
    [branchId, categoryId, debouncedSearch],
  );

  // -------------------- defaults
  useEffect(() => {
    if (!branchId && branches.data && branches.data[0]) {
      setBranchId(me?.branch_id || branches.data[0].branch_id);
    }
  }, [branches.data, branchId, me]);

  useEffect(() => {
    setTableId("");
  }, [branchId, orderType]);

  // -------------------- derived
  const subtotal = useMemo(
    () => cart.reduce((s, r) => s + r.unit_price * r.quantity, 0),
    [cart],
  );

  // 12% tax, 10% service (matches fn_place_order)
  const tax = subtotal * 0.12;
  const serviceCharge = subtotal * 0.1;
  const estimatedTotal = subtotal + tax + serviceCharge;

  const byCat = useMemo(() => {
    const map: Record<string, MenuItem[]> = {};
    for (const it of menu.data ?? []) (map[it.category_name] ||= []).push(it);
    return map;
  }, [menu.data]);

  const popularCategories = (categories.data ?? [])
    .filter((c) => c.items_count > 0)
    .slice(0, 10);

  // -------------------- handlers
  function addItem(m: MenuItem) {
    setCart((c) => {
      const found = c.find((r) => r.menu_item_id === m.menu_item_id);
      if (found)
        return c.map((r) =>
          r.menu_item_id === m.menu_item_id
            ? { ...r, quantity: r.quantity + 1 }
            : r,
        );
      return [
        ...c,
        {
          menu_item_id: m.menu_item_id,
          name: m.name,
          unit_price: Number(m.current_price),
          quantity: 1,
        },
      ];
    });
  }

  function changeQty(id: string, delta: number) {
    setCart((c) =>
      c
        .map((r) => (r.menu_item_id === id ? { ...r, quantity: r.quantity + delta } : r))
        .filter((r) => r.quantity > 0),
    );
  }

  function removeItem(id: string) {
    setCart((c) => c.filter((r) => r.menu_item_id !== id));
  }

  // Validation
  const canSubmit =
    !busy &&
    !!branchId &&
    cart.length > 0 &&
    (orderType !== "dine_in" || !!tableId);

  async function submit() {
    if (!canSubmit) return;
    setBusy(true);
    try {
      const res = await apiPost<{ order_id: string; total: string }>("/orders/", {
        branch_id: branchId,
        table_id: orderType === "dine_in" ? tableId : null,
        order_type: orderType,
        items: cart.map((r) => ({ menu_item_id: r.menu_item_id, quantity: r.quantity })),
        notes: notes || null,
      });
      toast.success(`Order placed — ${formatCurrency(res.total)}`);
      router.push(`/orders/${res.order_id}`);
    } catch (e: any) {
      toast.error(e?.message || "Failed to place order");
    } finally {
      setBusy(false);
    }
  }

  const availableTables = (tables.data ?? []).filter((t) => !t.is_occupied);
  const hasUnavailableTables = (tables.data ?? []).some((t) => t.is_occupied);

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap justify-between items-center gap-3">
        <h1 className="text-2xl font-bold">New order</h1>
        <Button onClick={submit} disabled={!canSubmit}>
          {busy ? "Placing…" : `Place order · ${formatCurrency(estimatedTotal)}`}
        </Button>
      </div>

      {(branches.error || menu.error || tables.error) && (
        <ErrorBanner message={branches.error || menu.error || tables.error || ""} />
      )}

      {/* Context selectors */}
      <Panel>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
          <label className="block">
            <div className="muted text-xs mb-1">Branch *</div>
            <select
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded-md px-2 py-2 text-sm"
              value={branchId}
              onChange={(e) => setBranchId(e.target.value)}
            >
              <option value="" disabled>
                Select branch…
              </option>
              {(branches.data ?? []).map((b) => (
                <option key={b.branch_id} value={b.branch_id}>
                  {b.name}
                  {b.city ? ` — ${b.city}` : ""}
                </option>
              ))}
            </select>
          </label>

          <label className="block">
            <div className="muted text-xs mb-1">Order type</div>
            <div className="grid grid-cols-3 gap-1">
              {(["dine_in", "takeaway", "delivery"] as OrderType[]).map((t) => (
                <button
                  key={t}
                  onClick={() => setOrderType(t)}
                  className={`py-2 rounded-md text-xs ${
                    orderType === t
                      ? "bg-brand-600 text-white"
                      : "bg-[var(--bg)] border border-[var(--border)] hover:border-brand-500"
                  }`}
                >
                  {t}
                </button>
              ))}
            </div>
          </label>

          <label className="block">
            <div className="muted text-xs mb-1">
              Table {orderType === "dine_in" ? "*" : "(n/a)"}
            </div>
            <select
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded-md px-2 py-2 text-sm disabled:opacity-50"
              value={tableId}
              onChange={(e) => setTableId(e.target.value)}
              disabled={orderType !== "dine_in" || !branchId || tables.loading}
            >
              <option value="">
                {orderType === "dine_in" ? "— select table —" : "n/a for takeaway/delivery"}
              </option>
              {availableTables.map((t) => (
                <option key={t.table_id} value={t.table_id}>
                  #{t.table_number} · {t.seats} seats
                  {t.zone_name ? ` · ${t.zone_name}` : ""}
                </option>
              ))}
            </select>
            {orderType === "dine_in" && hasUnavailableTables && (
              <div className="muted text-[10px] mt-1">
                Occupied tables hidden ({(tables.data ?? []).filter((t) => t.is_occupied).length})
              </div>
            )}
          </label>
        </div>

        {orderType === "dine_in" && !tableId && (
          <div className="text-[11px] mt-3 text-amber-600">
            Select a table before placing a dine-in order.
          </div>
        )}
      </Panel>

      {/* Menu + Cart */}
      <div className="grid grid-cols-1 lg:grid-cols-3 gap-5">
        <div className="lg:col-span-2 space-y-4">
          <div className="flex items-center gap-3">
            <input
              className="flex-1 bg-[var(--panel)] border border-[var(--border)] rounded-md px-3 py-2 text-sm focus:outline-none focus:border-brand-500"
              placeholder="Search menu…"
              value={search}
              onChange={(e) => setSearch(e.target.value)}
            />
          </div>

          {categories.data && (
            <div className="flex gap-1.5 overflow-x-auto pb-1">
              <Chip active={categoryId === null} onClick={() => setCategoryId(null)}>
                All
              </Chip>
              {popularCategories.map((c) => (
                <Chip
                  key={c.category_id}
                  active={categoryId === c.category_id}
                  onClick={() => setCategoryId(c.category_id)}
                >
                  {c.name}
                </Chip>
              ))}
            </div>
          )}

          {menu.loading ? (
            <Panel><SkeletonRows rows={4} cols={3} /></Panel>
          ) : (menu.data ?? []).length === 0 ? (
            <Panel>
              <div className="muted text-sm text-center py-8">
                No items available. Select a branch to load menu.
              </div>
            </Panel>
          ) : (
            Object.entries(byCat).map(([cat, items]) => (
              <Panel key={cat}>
                <div className="text-brand-500 text-sm font-bold mb-2">{cat}</div>
                <div className="grid grid-cols-1 md:grid-cols-2 gap-2">
                  {items.map((m) => (
                    <button
                      key={m.menu_item_id}
                      onClick={() => addItem(m)}
                      className="text-left border border-[var(--border)] rounded-md p-3 hover:border-brand-500 transition-all"
                    >
                      <div className="flex justify-between gap-2">
                        <div className="font-medium text-sm">{m.name}</div>
                        <div className="text-brand-500 font-bold text-sm shrink-0">
                          {formatCurrency(m.current_price)}
                        </div>
                      </div>
                    </button>
                  ))}
                </div>
              </Panel>
            ))
          )}
        </div>

        {/* Cart */}
        <div className="lg:col-span-1">
          <Panel className="sticky top-4 space-y-3">
            <div className="flex justify-between items-center">
              <div className="text-brand-500 font-bold">Cart</div>
              <div className="muted text-xs">{cart.length} items</div>
            </div>

            {cart.length === 0 && (
              <div className="muted text-xs py-4 text-center">
                Tap an item to add it to the cart
              </div>
            )}

            {cart.map((r) => (
              <div key={r.menu_item_id} className="flex items-center gap-2 text-sm">
                <div className="flex-1 min-w-0 truncate">{r.name}</div>
                <button
                  onClick={() => changeQty(r.menu_item_id, -1)}
                  className="w-6 h-6 border border-[var(--border)] rounded hover:border-brand-500"
                >
                  −
                </button>
                <div className="w-6 text-center">{r.quantity}</div>
                <button
                  onClick={() => changeQty(r.menu_item_id, +1)}
                  className="w-6 h-6 border border-[var(--border)] rounded hover:border-brand-500"
                >
                  +
                </button>
                <div className="w-20 text-right muted text-xs">
                  {formatCurrency(r.unit_price * r.quantity)}
                </div>
                <button
                  onClick={() => removeItem(r.menu_item_id)}
                  className="muted hover:text-red-600 text-xs"
                >
                  ✕
                </button>
              </div>
            ))}

            {cart.length > 0 && (
              <>
                <div className="border-t border-[var(--border)] pt-2 space-y-1 text-xs muted">
                  <Row label="Subtotal" value={formatCurrency(subtotal)} />
                  <Row label="Tax (12%)" value={formatCurrency(tax)} />
                  <Row label="Service (10%)" value={formatCurrency(serviceCharge)} />
                </div>
                <div className="flex justify-between text-sm font-bold text-brand-500">
                  <div>Estimated total</div>
                  <div>{formatCurrency(estimatedTotal)}</div>
                </div>
              </>
            )}

            <textarea
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded-md px-2 py-1.5 text-xs"
              placeholder="Notes (allergies, requests)…"
              rows={2}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
            />
            <Button
              onClick={submit}
              disabled={!canSubmit}
              className="w-full justify-center"
            >
              {busy ? "Placing…" : "Place order"}
            </Button>
            <div className="muted text-[10px] leading-relaxed">
              Items + stock decrement + totals run atomically inside <code>fn_place_order</code>.
              On stock shortage the whole transaction rolls back.
            </div>
          </Panel>
        </div>
      </div>
    </div>
  );
}

function Row({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex justify-between">
      <div>{label}</div>
      <div>{value}</div>
    </div>
  );
}
