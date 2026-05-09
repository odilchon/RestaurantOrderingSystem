"use client";
import Link from "next/link";
import { useEffect, useState } from "react";
import { BASE } from "@/lib/api";
import { Panel } from "@/components/ui";

type Stats = {
  base_tables: number;
  partitions: number;
  views: number;
  materialized_views: number;
  functions: number;
  triggers: number;
  indexes: number;
  rls_policies: number;
  db_roles: number;
};

export default function HomePage() {
  const [s, setS] = useState<Stats | null>(null);
  const [err, setErr] = useState<string | null>(null);

  useEffect(() => {
    fetch(`${BASE}/meta/stats`)
      .then((r) => (r.ok ? r.json() : Promise.reject(`HTTP ${r.status}`)))
      .then(setS)
      .catch((e) => setErr(String(e)));
  }, []);

  const cards = s
    ? [
        { k: s.base_tables, v: "base tables (3NF)" },
        { k: s.partitions, v: "monthly partitions on orders" },
        { k: s.functions, v: "PL/pgSQL functions" },
        { k: s.triggers, v: "triggers (audit, FTS, overlap)" },
        { k: s.materialized_views, v: "materialized views" },
        { k: s.rls_policies, v: "RLS policies" },
        { k: s.indexes, v: "indexes (B-tree, GIN, GiST, BRIN)" },
        { k: s.db_roles, v: "DB roles (least privilege)" },
      ]
    : [];

  return (
    <div className="max-w-4xl space-y-6">
      <div>
        <h1 className="text-3xl font-bold">Restaurant Ordering System</h1>
        <p className="muted mt-1">
          Multi-tenant SaaS backend for restaurant chains — AUCA COM-424.1 final project.
        </p>
      </div>

      <div className="flex flex-wrap gap-2">
        <Link href="/dashboard" className="bg-brand-600 hover:bg-brand-700 text-white px-3 py-2 rounded-md text-sm">
          Open dashboard →
        </Link>
        <Link href="/login" className="bg-[var(--panel)] border border-[var(--border)] hover:border-brand-500 px-3 py-2 rounded-md text-sm">
          Sign in
        </Link>
        <a
          href={`${BASE}/docs`}
          target="_blank"
          rel="noreferrer"
          className="bg-[var(--panel)] border border-[var(--border)] hover:border-brand-500 px-3 py-2 rounded-md text-sm"
        >
          Swagger UI ↗
        </a>
      </div>

      {err && (
        <Panel>
          <div className="text-red-600 text-xs">
            Could not load live stats: {err}. Is the backend up at <code>{BASE}</code>?
          </div>
        </Panel>
      )}

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {s
          ? cards.map((c) => (
              <div key={c.v} className="panel p-4">
                <div className="text-brand-500 text-2xl font-bold">{c.k}</div>
                <div className="muted text-sm">{c.v}</div>
              </div>
            ))
          : Array.from({ length: 8 }).map((_, i) => (
              <div key={i} className="panel p-4 animate-pulse">
                <div className="h-7 w-12 bg-[var(--border)] rounded mb-2" />
                <div className="h-3 w-24 bg-[var(--border)] rounded" />
              </div>
            ))}
      </div>

      <Panel>
        <div className="text-sm muted">
          Numbers above come from <code>GET /meta/stats</code> — a query over <code>pg_catalog</code>,
          not hardcoded constants. Schema changes reflect automatically.
        </div>
      </Panel>
    </div>
  );
}
