"use client";
import { useEffect, useMemo, useState } from "react";
import { apiGet, qs } from "@/lib/api";
import { useApp } from "@/lib/context";
import { useAsync, useDebounced } from "@/lib/hooks";
import { formatCurrency } from "@/lib/format";
import { Panel, Chip, SkeletonRows, EmptyState, ErrorBanner } from "@/components/ui";
import { BranchSelector } from "@/components/filters";

type Category = {
  category_id: string;
  name: string;
  items_count: number;
};

type MenuItem = {
  menu_item_id: string;
  category_id: string;
  category_name: string;
  name: string;
  description: string | null;
  current_price: number;
  preparation_minutes: number | null;
  calories: number | null;
};

type Sort = "category" | "name_asc" | "name_desc" | "price_asc" | "price_desc";

const SORTS: { key: Sort; label: string }[] = [
  { key: "category", label: "Category" },
  { key: "name_asc", label: "Name ↑" },
  { key: "name_desc", label: "Name ↓" },
  { key: "price_asc", label: "Price ↑" },
  { key: "price_desc", label: "Price ↓" },
];

export default function MenuPage() {
  const { branchId } = useApp();
  const [search, setSearch] = useState("");
  const [categoryId, setCategoryId] = useState<string | null>(null);
  const [sort, setSort] = useState<Sort>("category");
  const debouncedSearch = useDebounced(search, 250);

  const categories = useAsync<Category[]>(() => apiGet("/menu/categories"), []);
  const items = useAsync<MenuItem[]>(
    () =>
      apiGet(
        `/menu/${qs({
          search: debouncedSearch,
          category_id: categoryId,
          branch_id: branchId,
          sort,
        })}`,
      ),
    [debouncedSearch, categoryId, branchId, sort],
  );

  const byCat = useMemo(() => {
    const map: Record<string, MenuItem[]> = {};
    for (const it of items.data ?? []) (map[it.category_name] ||= []).push(it);
    return map;
  }, [items.data]);

  const popularCategories = (categories.data ?? []).filter((c) => c.items_count > 0);

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-2xl font-bold">Menu</h1>
        <div className="flex items-center gap-3">
          <BranchSelector />
          <select
            className="bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-1.5 text-sm"
            value={sort}
            onChange={(e) => setSort(e.target.value as Sort)}
          >
            {SORTS.map((s) => (
              <option key={s.key} value={s.key}>
                Sort: {s.label}
              </option>
            ))}
          </select>
        </div>
      </div>

      {/* Search bar */}
      <div className="relative">
        <input
          className="w-full bg-[var(--panel)] border border-[var(--border)] rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:border-brand-500"
          placeholder="Instant search (name / description)…"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {search && (
          <button
            onClick={() => setSearch("")}
            className="absolute right-3 top-1/2 -translate-y-1/2 muted text-xs hover:text-brand-500"
          >
            ✕ clear
          </button>
        )}
      </div>

      {/* Category chips */}
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
              {c.name} · {c.items_count}
            </Chip>
          ))}
        </div>
      )}

      {items.error && <ErrorBanner message={items.error} onRetry={items.reload} />}

      {items.loading && <Panel><SkeletonRows rows={4} cols={4} /></Panel>}

      {!items.loading &&
        items.data &&
        (items.data.length === 0 ? (
          <EmptyState
            title="No items match these filters"
            hint={search ? `Nothing found for "${search}"` : undefined}
          />
        ) : (
          Object.entries(byCat).map(([cat, its]) => (
            <Panel key={cat}>
              <div className="text-brand-500 text-sm font-bold mb-3">
                {cat}
                <span className="muted text-xs font-normal ml-2">({its.length})</span>
              </div>
              <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                {its.map((it) => (
                  <MenuItemCard key={it.menu_item_id} item={it} />
                ))}
              </div>
            </Panel>
          ))
        ))}
    </div>
  );
}

function MenuItemCard({ item }: { item: MenuItem }) {
  return (
    <div className="border border-[var(--border)] rounded-lg p-3 hover:border-brand-500 transition-all group">
      <div className="flex justify-between gap-2">
        <div className="min-w-0 flex-1">
          <div className="font-medium text-sm">{item.name}</div>
          {item.description && (
            <div className="muted text-xs mt-1 line-clamp-2">{item.description}</div>
          )}
          <div className="flex gap-3 mt-2 text-[10px] muted">
            {item.preparation_minutes != null && <span>⏱ {item.preparation_minutes} min</span>}
            {item.calories != null && <span>🔥 {item.calories} kcal</span>}
          </div>
        </div>
        <div className="text-brand-500 font-bold text-sm shrink-0">
          {formatCurrency(item.current_price)}
        </div>
      </div>
    </div>
  );
}
