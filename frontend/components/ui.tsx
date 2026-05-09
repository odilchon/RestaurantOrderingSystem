"use client";
import { ReactNode } from "react";

// ---------------------------------------------------------------------------
// Panels / cards
// ---------------------------------------------------------------------------

export function Panel({
  children,
  className = "",
}: {
  children: ReactNode;
  className?: string;
}) {
  return <div className={`panel p-4 ${className}`}>{children}</div>;
}

// ---------------------------------------------------------------------------
// Loading / Empty / Error states
// ---------------------------------------------------------------------------

export function Skeleton({ className = "" }: { className?: string }) {
  return (
    <div
      className={`animate-pulse bg-[var(--border)] rounded ${className}`}
      style={{ minHeight: 12 }}
    />
  );
}

export function SkeletonRows({ rows = 4, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="space-y-2">
      {Array.from({ length: rows }).map((_, r) => (
        <div key={r} className="grid gap-2" style={{ gridTemplateColumns: `repeat(${cols}, 1fr)` }}>
          {Array.from({ length: cols }).map((_, c) => (
            <Skeleton key={c} className="h-4" />
          ))}
        </div>
      ))}
    </div>
  );
}

export function EmptyState({
  title = "Nothing here yet",
  hint,
  action,
}: {
  title?: string;
  hint?: string;
  action?: ReactNode;
}) {
  return (
    <div className="panel p-8 text-center space-y-2">
      <div className="text-sm font-medium">{title}</div>
      {hint && <div className="muted text-xs">{hint}</div>}
      {action && <div className="pt-2">{action}</div>}
    </div>
  );
}

export function ErrorBanner({
  message,
  onRetry,
}: {
  message: string;
  onRetry?: () => void;
}) {
  return (
    <div className="panel p-3 border-l-4 border-red-500 flex items-center justify-between">
      <div className="text-red-600 text-xs">{message}</div>
      {onRetry && (
        <button
          onClick={onRetry}
          className="text-xs text-brand-500 hover:text-brand-400 ml-3"
        >
          Retry
        </button>
      )}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------

export function Button({
  children,
  onClick,
  type = "button",
  variant = "primary",
  disabled,
  size = "md",
  className = "",
}: {
  children: ReactNode;
  onClick?: () => void;
  type?: "button" | "submit";
  variant?: "primary" | "secondary" | "danger" | "ghost";
  disabled?: boolean;
  size?: "sm" | "md";
  className?: string;
}) {
  const base =
    "rounded-md font-medium transition-all disabled:opacity-50 disabled:cursor-not-allowed";
  const sizes = {
    sm: "px-2.5 py-1 text-xs",
    md: "px-3 py-2 text-sm",
  };
  const variants = {
    primary: "bg-brand-500 hover:bg-brand-600 text-white shadow-card",
    secondary:
      "bg-white border border-[var(--border)] hover:bg-[var(--bg)] text-[var(--text)]",
    danger: "bg-red-50 text-red-600 hover:bg-red-100 border border-red-200",
    ghost: "text-[var(--text)] hover:bg-[var(--bg)]",
  };
  return (
    <button
      type={type}
      onClick={onClick}
      disabled={disabled}
      className={`${base} ${sizes[size]} ${variants[variant]} ${className}`}
    >
      {children}
    </button>
  );
}

// ---------------------------------------------------------------------------
// Chip (filter button)
// ---------------------------------------------------------------------------

export function Chip({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={`px-3 py-1.5 rounded-full text-xs font-medium transition-all whitespace-nowrap ${
        active
          ? "bg-brand-500 text-white shadow-card"
          : "bg-white border border-[var(--border)] text-[var(--text)] hover:border-brand-400 hover:text-brand-600"
      }`}
    >
      {children}
    </button>
  );
}

// ---------------------------------------------------------------------------
// Role badge
// ---------------------------------------------------------------------------

export function RoleBadge({ role }: { role: string }) {
  const colors: Record<string, string> = {
    super_admin: "bg-purple-100 text-purple-700 border-purple-200",
    tenant_owner: "bg-brand-100 text-brand-700 border-brand-200",
    manager: "bg-blue-100 text-blue-700 border-blue-200",
    waiter: "bg-green-100 text-green-700 border-green-200",
    chef: "bg-yellow-100 text-yellow-700 border-yellow-200",
    cashier: "bg-teal-100 text-teal-700 border-teal-200",
    customer: "bg-gray-100 text-gray-700 border-gray-200",
  };
  const cls = colors[role] || "bg-gray-100 text-gray-700 border-gray-200";
  return (
    <span className={`px-2 py-0.5 rounded-md border text-[10px] uppercase tracking-wide font-semibold ${cls}`}>
      {role.replace(/_/g, " ")}
    </span>
  );
}

// ---------------------------------------------------------------------------
// Status badge (for orders)
// ---------------------------------------------------------------------------

export function StatusBadge({ status }: { status: string }) {
  const colors: Record<string, string> = {
    draft: "text-gray-500",
    pending: "text-amber-600",
    confirmed: "text-blue-600",
    preparing: "text-blue-600",
    ready: "text-cyan-600",
    served: "text-green-600",
    completed: "text-green-600",
    paid: "text-green-600",
    cancelled: "text-red-600",
  };
  return (
    <span className={`${colors[status] || "text-[var(--text)]"} text-xs font-medium`}>
      {status}
    </span>
  );
}
