"use client";
import {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
} from "react";
import { apiGet, clearToken, getToken } from "./api";
import { DEFAULT_PERIOD, PeriodKey } from "./period";

// ---------------------------------------------------------------------------
// Session
// ---------------------------------------------------------------------------

export interface Me {
  user_id: string;
  tenant_id: string | null;
  tenant_name: string | null;
  tenant_slug: string | null;
  role: string;
  email: string | null;
  full_name: string | null;
  branch_id: string | null;
  branch_name: string | null;
}

export interface BranchLite {
  branch_id: string;
  name: string;
  address: string | null;
  city: string | null;
  is_active: boolean;
}

// ---------------------------------------------------------------------------
// Context shape
// ---------------------------------------------------------------------------

interface AppContextValue {
  me: Me | null;
  meLoading: boolean;
  meError: string | null;
  reloadMe: () => void;
  logout: () => void;

  branches: BranchLite[];
  branchesLoading: boolean;

  // Global dashboard filters
  period: PeriodKey;
  setPeriod: (p: PeriodKey) => void;

  branchId: string | null; // null = "All branches"
  setBranchId: (b: string | null) => void;
}

const AppContext = createContext<AppContextValue | null>(null);

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

export function AppProvider({ children }: { children: ReactNode }) {
  const [me, setMe] = useState<Me | null>(null);
  const [meLoading, setMeLoading] = useState(false);
  const [meError, setMeError] = useState<string | null>(null);

  const [branches, setBranches] = useState<BranchLite[]>([]);
  const [branchesLoading, setBranchesLoading] = useState(false);

  const [period, setPeriod] = useState<PeriodKey>(DEFAULT_PERIOD);
  const [branchId, setBranchId] = useState<string | null>(null);

  const reloadMe = useCallback(() => {
    if (!getToken()) {
      setMe(null);
      return;
    }
    setMeLoading(true);
    setMeError(null);
    apiGet<Me>("/auth/me")
      .then((m) => {
        setMe(m);
        setMeLoading(false);
      })
      .catch((e) => {
        setMeError(e?.message ?? String(e));
        setMeLoading(false);
      });
  }, []);

  const loadBranches = useCallback(() => {
    if (!getToken()) return;
    setBranchesLoading(true);
    apiGet<BranchLite[]>("/places/branches")
      .then((b) => setBranches(b))
      .catch(() => {})
      .finally(() => setBranchesLoading(false));
  }, []);

  useEffect(() => {
    reloadMe();
    loadBranches();
  }, [reloadMe, loadBranches]);

  const logout = useCallback(() => {
    clearToken();
    setMe(null);
    if (typeof window !== "undefined") {
      window.localStorage.removeItem("ros_filters");
      window.location.href = "/login";
    }
  }, []);

  // Persist filters across route changes
  useEffect(() => {
    if (typeof window === "undefined") return;
    const saved = window.localStorage.getItem("ros_filters");
    if (saved) {
      try {
        const { period: p, branchId: b } = JSON.parse(saved);
        if (p) setPeriod(p);
        if (b) setBranchId(b);
      } catch {
        /* ignore */
      }
    }
  }, []);

  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem(
      "ros_filters",
      JSON.stringify({ period, branchId }),
    );
  }, [period, branchId]);

  // If the persisted branchId belongs to a different tenant (e.g. after
  // re-login as another owner), drop it once the real branch list arrives.
  useEffect(() => {
    if (branchesLoading || branches.length === 0) return;
    if (branchId && !branches.some((b) => b.branch_id === branchId)) {
      setBranchId(null);
    }
  }, [branches, branchesLoading, branchId]);

  const value: AppContextValue = useMemo(
    () => ({
      me,
      meLoading,
      meError,
      reloadMe,
      logout,
      branches,
      branchesLoading,
      period,
      setPeriod,
      branchId,
      setBranchId,
    }),
    [me, meLoading, meError, reloadMe, logout, branches, branchesLoading, period, branchId],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) throw new Error("useApp must be called inside <AppProvider>");
  return ctx;
}
