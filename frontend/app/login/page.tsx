"use client";
import { useState } from "react";
import { useRouter } from "next/navigation";
import { login } from "@/lib/api";
import { Button } from "@/components/ui";

export default function LoginPage() {
  const router = useRouter();
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function onSubmit(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true);
    setErr(null);
    try {
      await login(email, password);
      router.push("/dashboard");
      // Force full reload so the AppContext picks up /auth/me.
      setTimeout(() => window.location.reload(), 50);
    } catch (x: unknown) {
      setErr(x instanceof Error ? x.message : String(x));
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center px-4">
      <div className="w-full max-w-sm">
        <div className="text-center mb-8">
          <div className="text-brand-500 font-bold text-3xl tracking-tight mb-1">ROS</div>
          <div className="muted text-sm">Restaurant Ordering System</div>
        </div>
        <form onSubmit={onSubmit} className="panel p-6 space-y-4">
          <h1 className="text-xl font-bold text-center">Sign in</h1>
          <div>
            <div className="muted text-xs mb-1">Email</div>
            <input
              id="login-email"
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:border-brand-500"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              autoComplete="email"
              autoFocus
            />
          </div>
          <div>
            <div className="muted text-xs mb-1">Password</div>
            <input
              id="login-password"
              type="password"
              className="w-full bg-[var(--bg)] border border-[var(--border)] rounded-lg px-3 py-2.5 text-sm focus:outline-none focus:border-brand-500"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              autoComplete="current-password"
            />
          </div>
          {err && (
            <div className="text-red-600 text-xs bg-red-50 p-2 rounded-lg border border-red-200">
              {err}
            </div>
          )}
          <Button type="submit" disabled={busy} className="w-full py-2.5">
            {busy ? "Signing in…" : "Sign in"}
          </Button>
        </form>
      </div>
    </div>
  );
}
