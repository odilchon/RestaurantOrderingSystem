"use client";
import { useApp } from "@/lib/context";
import { PERIODS, PeriodKey } from "@/lib/period";
import { Chip } from "./ui";

// ---------------------------------------------------------------------------
// PeriodSelector — chips. Bound to global AppContext by default but can be
// overridden via props for page-local state.
// ---------------------------------------------------------------------------

export function PeriodSelector({
  value,
  onChange,
  className = "",
}: {
  value?: PeriodKey;
  onChange?: (k: PeriodKey) => void;
  className?: string;
}) {
  const app = useApp();
  const current = value ?? app.period;
  const set = onChange ?? app.setPeriod;
  return (
    <div className={`flex flex-wrap gap-1.5 ${className}`}>
      {PERIODS.map((p) => (
        <Chip key={p.key} active={current === p.key} onClick={() => set(p.key)}>
          {p.label}
        </Chip>
      ))}
    </div>
  );
}

// ---------------------------------------------------------------------------
// BranchSelector — dropdown with "All branches" option.
// ---------------------------------------------------------------------------

export function BranchSelector({
  value,
  onChange,
  includeAll = true,
  className = "",
}: {
  value?: string | null;
  onChange?: (b: string | null) => void;
  includeAll?: boolean;
  className?: string;
}) {
  const app = useApp();
  const current = value === undefined ? app.branchId : value;
  const set = onChange ?? app.setBranchId;
  return (
    <select
      className={`bg-[var(--bg)] border border-[var(--border)] rounded-md px-3 py-1.5 text-sm ${className}`}
      value={current ?? ""}
      onChange={(e) => set(e.target.value ? e.target.value : null)}
    >
      {includeAll && <option value="">All branches</option>}
      {app.branches.map((b) => (
        <option key={b.branch_id} value={b.branch_id}>
          {b.name}
          {b.city ? ` — ${b.city}` : ""}
        </option>
      ))}
    </select>
  );
}
