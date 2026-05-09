"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useApp } from "@/lib/context";
import { RoleBadge } from "@/components/ui";

const NAV = [
  { href: "/dashboard", label: "Dashboard", icon: "📊" },
  { href: "/menu", label: "Menu", icon: "🍽️" },
  { href: "/orders", label: "Orders", icon: "📋" },
  { href: "/inventory", label: "Inventory", icon: "📦" },
  { href: "/reports", label: "Reports", icon: "📈" },
];

export function Sidebar() {
  const pathname = usePathname();
  const { me, logout } = useApp();

  if (pathname === "/login") return null;

  return (
    <aside className="sidebar w-60 p-5 flex flex-col shrink-0 m-3 rounded-2xl">
      {/* Branding */}
      <div className="mb-6">
        <div className="text-brand-500 font-extrabold text-xl tracking-tight">ROS</div>
        <div className="muted text-[11px] mt-0.5">Restaurant Ordering System</div>
      </div>

      {/* Tenant context */}
      {me?.tenant_name && (
        <div className="rounded-xl p-3 mb-4 space-y-1 bg-white/5 border border-white/5">
          <div className="muted text-[10px] uppercase tracking-wider">Tenant</div>
          <div className="text-sm font-semibold truncate text-white">
            {me.tenant_name}
          </div>
          {me.branch_name && (
            <>
              <div className="muted text-[10px] uppercase tracking-wider pt-1">Branch</div>
              <div className="text-xs truncate">{me.branch_name}</div>
            </>
          )}
        </div>
      )}

      {/* Navigation */}
      <nav className="flex flex-col gap-1 flex-1">
        {NAV.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            className={`nav-link flex items-center gap-2.5 px-3 py-2 rounded-lg text-sm ${
              pathname.startsWith(item.href) ? "active font-semibold" : ""
            }`}
          >
            <span className="text-base">{item.icon}</span>
            {item.label}
          </Link>
        ))}
      </nav>

      {/* User section */}
      <div className="pt-4 border-t border-white/5">
        {me ? (
          <div className="space-y-2">
            <div className="flex items-center justify-between gap-2">
              <div className="min-w-0">
                <div className="text-sm font-semibold truncate text-white">
                  {me.full_name || me.email || "User"}
                </div>
                <div className="muted text-[10px] truncate">{me.email}</div>
              </div>
              <RoleBadge role={me.role} />
            </div>
            <button
              onClick={logout}
              className="w-full text-left px-3 py-2 rounded-lg text-xs muted hover:text-brand-400 hover:bg-white/5 transition-all"
            >
              Sign out
            </button>
          </div>
        ) : (
          <Link
            href="/login"
            className="block px-3 py-2 rounded-lg text-sm text-brand-500 hover:bg-white/5 transition-all"
          >
            Sign in
          </Link>
        )}
      </div>
    </aside>
  );
}
