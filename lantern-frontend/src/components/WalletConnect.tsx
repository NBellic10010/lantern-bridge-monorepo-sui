'use client';

import { useConnectModal, useWallet } from '@mysten/dapp-kit';

export default function WalletConnect() {
  const { openConnectModal } = useConnectModal();
  const { connect } = useWallet();

  const handleConnect = () => {
    openConnectModal?.();
  };

  return (
    <div className="flex flex-col items-center justify-center min-h-[60vh]">
      <div className="text-center space-y-6">
        <div className="text-6xl">🏮</div>
        <h1 className="text-4xl font-bold text-white">
          Lantern V1.0
        </h1>
        <p className="text-xl text-slate-400 max-w-md">
          一鍵跨鏈生息，自動將您的 USDC 存入 Navi Protocol 產生被動收益
        </p>

        <div className="py-8">
          <button
            onClick={handleConnect}
            className="px-8 py-4 bg-emerald-500 hover:bg-emerald-600 text-white text-lg font-semibold rounded-xl transition-all transform hover:scale-105 shadow-lg shadow-emerald-500/25"
          >
            連接錢包開始
          </button>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-6 pt-8">
          <div className="bg-slate-800/50 p-6 rounded-xl border border-slate-700">
            <div className="text-3xl mb-2">⚡</div>
            <h3 className="text-white font-semibold">零 Gas 費</h3>
            <p className="text-slate-400 text-sm mt-2">
              協議代付 Gas 費用
            </p>
          </div>
          <div className="bg-slate-800/50 p-6 rounded-xl border border-slate-700">
            <div className="text-3xl mb-2">📈</div>
            <h3 className="text-white font-semibold">自動生息</h3>
            <p className="text-slate-400 text-sm mt-2">
              存入當下立即開始產生收益
            </p>
          </div>
          <div className="bg-slate-800/50 p-6 rounded-xl border border-slate-700">
            <div className="text-3xl mb-2">🔒</div>
            <h3 className="text-white font-semibold">安全可靠</h3>
            <p className="text-slate-400 text-sm mt-2">
              代碼經過審計
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
