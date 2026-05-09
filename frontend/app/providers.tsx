"use client";
import { ReactNode } from "react";
import { AppProvider } from "@/lib/context";
import { ToastProvider } from "@/lib/toast";

export default function Providers({ children }: { children: ReactNode }) {
  return (
    <ToastProvider>
      <AppProvider>{children}</AppProvider>
    </ToastProvider>
  );
}
