"use client";

import { WagmiProvider } from "wagmi";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { useState, type ReactNode } from "react";
import { config } from "@/lib/wagmi";
import { VaultProvider } from "@/components/vaultStore";

export function Providers({ children }: { children: ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={queryClient}>
        <VaultProvider>{children}</VaultProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
