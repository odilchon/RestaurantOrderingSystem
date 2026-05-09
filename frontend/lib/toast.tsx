"use client";
import {
  createContext,
  ReactNode,
  useCallback,
  useContext,
  useMemo,
  useState,
} from "react";

type ToastKind = "success" | "error" | "info";
interface Toast {
  id: number;
  kind: ToastKind;
  message: string;
}

interface ToastCtx {
  toast: (kind: ToastKind, message: string) => void;
  success: (m: string) => void;
  error: (m: string) => void;
  info: (m: string) => void;
}

const Ctx = createContext<ToastCtx | null>(null);

export function ToastProvider({ children }: { children: ReactNode }) {
  const [toasts, setToasts] = useState<Toast[]>([]);

  const push = useCallback((kind: ToastKind, message: string) => {
    const id = Date.now() + Math.random();
    setToasts((xs) => [...xs, { id, kind, message }]);
    setTimeout(
      () => setToasts((xs) => xs.filter((t) => t.id !== id)),
      kind === "error" ? 6000 : 3500,
    );
  }, []);

  const value = useMemo<ToastCtx>(
    () => ({
      toast: push,
      success: (m) => push("success", m),
      error: (m) => push("error", m),
      info: (m) => push("info", m),
    }),
    [push],
  );

  return (
    <Ctx.Provider value={value}>
      {children}
      <div className="fixed bottom-5 right-5 z-50 flex flex-col gap-2">
        {toasts.map((t) => (
          <div
            key={t.id}
            className={`panel px-4 py-2 text-sm shadow-lg border-l-4 max-w-sm ${
              t.kind === "success"
                ? "border-green-500 text-green-300"
                : t.kind === "error"
                  ? "border-red-500 text-red-300"
                  : "border-brand-500 text-brand-300"
            }`}
          >
            {t.message}
          </div>
        ))}
      </div>
    </Ctx.Provider>
  );
}

export function useToast(): ToastCtx {
  const c = useContext(Ctx);
  if (!c) throw new Error("useToast must be inside <ToastProvider>");
  return c;
}
