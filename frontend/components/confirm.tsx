"use client";
import { ReactNode, useState } from "react";
import { Button } from "./ui";

export interface ConfirmOptions {
  title: string;
  message?: string;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
}

/**
 * Simple imperative confirm dialog hook.
 * Usage:
 *   const { Dialog, confirm } = useConfirm();
 *   ...
 *   if (await confirm({ title: "Cancel order?", destructive: true })) { ... }
 *   <Dialog />
 */
export function useConfirm() {
  const [opts, setOpts] = useState<ConfirmOptions | null>(null);
  const [resolver, setResolver] = useState<((v: boolean) => void) | null>(null);

  function confirm(o: ConfirmOptions): Promise<boolean> {
    return new Promise((resolve) => {
      setOpts(o);
      setResolver(() => resolve);
    });
  }

  function finish(v: boolean) {
    if (resolver) resolver(v);
    setOpts(null);
    setResolver(null);
  }

  const Dialog = (): ReactNode => {
    if (!opts) return null;
    return (
      <div
        className="fixed inset-0 bg-black/60 z-40 flex items-center justify-center p-4"
        onClick={() => finish(false)}
      >
        <div
          className="panel p-5 max-w-md w-full space-y-3"
          onClick={(e) => e.stopPropagation()}
        >
          <div className="text-lg font-bold">{opts.title}</div>
          {opts.message && <div className="muted text-sm">{opts.message}</div>}
          <div className="flex gap-2 justify-end pt-2">
            <Button variant="secondary" onClick={() => finish(false)}>
              {opts.cancelLabel ?? "Cancel"}
            </Button>
            <Button
              variant={opts.destructive ? "danger" : "primary"}
              onClick={() => finish(true)}
            >
              {opts.confirmLabel ?? "Confirm"}
            </Button>
          </div>
        </div>
      </div>
    );
  };

  return { Dialog, confirm };
}
