'use client';

import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { SuiClientProvider, WalletProvider } from '@mysten/dapp-kit';
import { useState } from 'react';

// Sui Mainnet RPC
const SUI_MAINNET = 'https://rpc.mainnet.sui.io';

export function Providers({ children }: { children: React.ReactNode }) {
  const [queryClient] = useState(() => new QueryClient());

  return (
    <QueryClientProvider client={queryClient}>
      <SuiClientProvider
        networks={{ mainnet: SUI_MAINNET, testnet: SUI_MAINNET }}
        defaultNetwork="mainnet"
      >
        <WalletProvider autoConnect>
          {children}
        </WalletProvider>
      </SuiClientProvider>
    </QueryClientProvider>
  );
}
