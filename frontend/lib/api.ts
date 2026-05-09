"use client";

export const BASE =
  process.env.NEXT_PUBLIC_API_URL || "http://localhost:8000";

const TOKEN_KEY = "ros_token";

// ---------------------------------------------------------------------------
// Token storage
// ---------------------------------------------------------------------------

export function getToken(): string | null {
  if (typeof window === "undefined") return null;
  return window.localStorage.getItem(TOKEN_KEY);
}
export function setToken(t: string) {
  window.localStorage.setItem(TOKEN_KEY, t);
}
export function clearToken() {
  window.localStorage.removeItem(TOKEN_KEY);
}
export function isLoggedIn(): boolean {
  return !!getToken();
}
export function logout() {
  clearToken();
  if (typeof window !== "undefined") window.location.href = "/login";
}

// ---------------------------------------------------------------------------
// Typed errors
// ---------------------------------------------------------------------------

export class ApiError extends Error {
  status: number;
  detail?: string;
  constructor(status: number, message: string, detail?: string) {
    super(message);
    this.status = status;
    this.detail = detail;
  }
}

function humanize(status: number, detail: string | undefined, fallback: string): string {
  if (status === 0) return "Cannot reach the backend. Is it running on " + BASE + "?";
  if (status === 401) return "Session expired — please sign in again.";
  if (status === 403) return "You don't have permission to do that.";
  if (status === 404) return detail || "Not found.";
  if (status === 409) return detail || "Conflict.";
  if (status === 422) return detail || "Invalid input.";
  if (status >= 500) return "Server error" + (detail ? ` — ${detail}` : "");
  return detail || fallback || `HTTP ${status}`;
}

// ---------------------------------------------------------------------------
// Low-level fetch
// ---------------------------------------------------------------------------

async function _fetch(path: string, init: RequestInit = {}): Promise<Response> {
  const token = getToken();
  const headers: Record<string, string> = {
    "content-type": "application/json",
    ...(init.headers as Record<string, string> | undefined),
  };
  if (token) headers.authorization = `Bearer ${token}`;
  try {
    return await fetch(`${BASE}${path}`, { ...init, headers, cache: "no-store" });
  } catch (e) {
    throw new ApiError(0, "Cannot reach the backend. Is it running on " + BASE + "?");
  }
}

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const res = await _fetch(path, init);

  if (res.status === 401) {
    clearToken();
    if (typeof window !== "undefined" && !window.location.pathname.startsWith("/login")) {
      window.location.href = "/login";
    }
    throw new ApiError(401, "Session expired. Redirecting to login.");
  }

  if (!res.ok) {
    let detail: string | undefined;
    try {
      const body = await res.json();
      detail = typeof body.detail === "string" ? body.detail : JSON.stringify(body.detail);
    } catch {
      try {
        detail = await res.text();
      } catch {
        detail = undefined;
      }
    }
    throw new ApiError(res.status, humanize(res.status, detail, res.statusText), detail);
  }

  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

// Short-hand helpers
export const apiGet = <T,>(path: string) => api<T>(path);
export const apiPost = <T,>(path: string, body?: unknown) =>
  api<T>(path, { method: "POST", body: body !== undefined ? JSON.stringify(body) : undefined });
export const apiPut = <T,>(path: string, body?: unknown) =>
  api<T>(path, { method: "PUT", body: body !== undefined ? JSON.stringify(body) : undefined });
export const apiDelete = <T,>(path: string) => api<T>(path, { method: "DELETE" });

// ---------------------------------------------------------------------------
// Auth
// ---------------------------------------------------------------------------

export async function login(username: string, password: string): Promise<void> {
  const body = new URLSearchParams({ username, password });
  let res: Response;
  try {
    res = await fetch(`${BASE}/auth/login`, {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch {
    throw new ApiError(0, "Cannot reach the backend. Is it running on " + BASE + "?");
  }
  if (!res.ok) {
    let detail: string | undefined;
    try {
      detail = (await res.json()).detail;
    } catch {
      detail = await res.text();
    }
    throw new ApiError(
      res.status,
      res.status === 401 ? "Invalid email or password" : detail || res.statusText,
      detail,
    );
  }
  const data = (await res.json()) as { access_token: string };
  setToken(data.access_token);
}

// Helper to compose query strings while dropping undefined / empty
export function qs(params: Record<string, unknown>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === "") continue;
    p.set(k, String(v));
  }
  const s = p.toString();
  return s ? `?${s}` : "";
}
