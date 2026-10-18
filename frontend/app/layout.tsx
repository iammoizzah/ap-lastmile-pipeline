import "./globals.css";
import type { ReactNode } from "react";

export const metadata = { title: "Invoice review", description: "Human review queue for AI-extracted invoices" };

export default function RootLayout({ children }: { children: ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
