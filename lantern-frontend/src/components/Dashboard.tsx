'use client';

import { useState } from 'react';
import { useWallet } from '@mysten/dapp-kit';
import Header from '@/components/Header';
import DepositPanel from '@/components/DepositPanel';
import YieldDisplay from '@/components/YieldDisplay';
import WalletConnect from '@/components/WalletConnect';

export default function Dashboard() {
  const { currentAccount } = useWallet();
  const [isDepositModalOpen, setIsDepositModalOpen] = useState(false);

  return (
    <div className="min-h-screen flex flex-col">
      <Header />

      <main className="flex-1 container mx-auto px-4 py-8">
        {currentAccount ? (
          <div className="grid grid-cols-1 lg:grid-cols-2 gap-8">
            {/* 左側：餘額和存入 */}
            <div className="space-y-6">
              <YieldDisplay />
              <DepositPanel onDeposit={() => setIsDepositModalOpen(true)} />
            </div>

            {/* 右側：收益信息和統計 */}
            <div className="space-y-6">
              <div className="bg-slate-800 rounded-2xl p-6 border border-slate-700">
                <h2 className="text-xl font-semibold text-white mb-4">
                  📈 收益預測
                </h2>
                <div className="space-y-4">
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">每日預估收益</span>
                    <span className="text-emerald-400 font-mono">+$1.43</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">每週預估收益</span>
                    <span className="text-emerald-400 font-mono">+$10.02</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">每月預估收益</span>
                    <span className="text-emerald-400 font-mono">+$43.08</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">每年預估收益</span>
                    <span className="text-emerald-400 font-mono">+$524.30</span>
                  </div>
                </div>
              </div>

              <div className="bg-slate-800 rounded-2xl p-6 border border-slate-700">
                <h2 className="text-xl font-semibold text-white mb-4">
                  📊 協議統計
                </h2>
                <div className="space-y-4">
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">總存款 (TVL)</span>
                    <span className="text-white font-mono">$1,234,567</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">總用戶數</span>
                    <span className="text-white font-mono">1,234</span>
                  </div>
                  <div className="flex justify-between items-center">
                    <span className="text-slate-400">當前 APY</span>
                    <span className="text-emerald-400 font-mono">5.23%</span>
                  </div>
                </div>
              </div>
            </div>
          </div>
        ) : (
          <WalletConnect />
        )}
      </main>
    </div>
  );
}
