export function formatCurrency(value: number | string, currency = "KGS"): string {
  const n = typeof value === "string" ? parseFloat(value) : value;
  if (!isFinite(n)) return "—";
  // Use ru-RU grouping, drop the currency symbol and append "сом" manually to
  // avoid inconsistent browser locale data.
  const body = new Intl.NumberFormat("ru-RU", {
    minimumFractionDigits: 0,
    maximumFractionDigits: 2,
  }).format(n);
  return `${body} ${currency === "KGS" ? "сом" : currency}`;
}

export function formatCompact(value: number): string {
  if (!isFinite(value)) return "—";
  if (Math.abs(value) >= 1_000_000) return (value / 1_000_000).toFixed(1) + "M";
  if (Math.abs(value) >= 1_000) return (value / 1_000).toFixed(1) + "k";
  return value.toFixed(0);
}

export function formatDate(s: string | Date): string {
  const d = typeof s === "string" ? new Date(s) : s;
  return d.toLocaleString("ru-RU", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

export function formatDateOnly(s: string | Date): string {
  const d = typeof s === "string" ? new Date(s) : s;
  return d.toLocaleDateString("ru-RU", {
    day: "2-digit",
    month: "short",
  });
}

export function shortId(id: string): string {
  return id.slice(0, 8);
}
