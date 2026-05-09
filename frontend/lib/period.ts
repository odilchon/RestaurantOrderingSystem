export type PeriodKey = "today" | "7d" | "14d" | "30d" | "90d" | "all" | "custom";

export interface Period {
  key: PeriodKey;
  label: string;
  days: number; // days to pass to backend. 0 = today, 9999 = all-time sentinel
}

export const PERIODS: Period[] = [
  { key: "today", label: "Today", days: 1 },
  { key: "7d", label: "7 days", days: 7 },
  { key: "14d", label: "14 days", days: 14 },
  { key: "30d", label: "30 days", days: 30 },
  { key: "90d", label: "90 days", days: 90 },
  { key: "all", label: "All time", days: 3650 },
];

export const DEFAULT_PERIOD: PeriodKey = "14d";

export function periodByKey(k: PeriodKey): Period {
  return PERIODS.find((p) => p.key === k) || PERIODS[2];
}
