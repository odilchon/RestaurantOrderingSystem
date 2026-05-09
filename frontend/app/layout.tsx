import type { Metadata } from "next";
import { ReactNode } from "react";
import "./globals.css";
import { Sidebar } from "./Sidebar";
import Providers from "./providers";

export const metadata: Metadata = {
  title: "Restaurant Ordering System",
  description:
    "Multi-tenant SaaS POS — AUCA COM-424 Databases final project. " +
    "Demonstrates RLS, partitioning, ACID transactions, and full-text search.",
};

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <head>
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Plus+Jakarta+Sans:wght@400;500;600;700;800&family=DM+Sans:wght@400;500;700&display=swap"
          rel="stylesheet"
        />
      </head>
      <body>
        <Providers>
          <div className="min-h-screen flex">
            <Sidebar />
            <main className="flex-1 p-8 overflow-auto">{children}</main>
          </div>
        </Providers>
      </body>
    </html>
  );
}
