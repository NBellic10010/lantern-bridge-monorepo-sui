'use client';

interface DepositPanelProps {
  onDeposit: () => void;
}

export default function DepositPanel({ onDeposit }: DepositPanelProps) {
  return (
    <div className="bg-slate-800 rounded-2xl p-6 border border-slate-700">
      <h2 className="text-xl font-semibold text-white mb-4">
        💰 存入 USDC
      </h2>

      <div className="space-y-4">
        <div>
          <label className="block text-sm text-slate-400 mb-2">
            存入金額 (USDC)
          </label>
          <div className="relative">
            <input
              type="number"
              placeholder="0.00"
              className="w-full bg-slate-900 border border-slate-600 rounded-lg px-4 py-3 text-white text-xl font-mono focus:outline-none focus:border-emerald-500"
            />
            <span className="absolute right-4 top-1/2 -translate-y-1/2 text-slate-400">
              USDC
            </span>
          </div>
          <div className="flex justify-between mt-2 text-sm">
            <button className="text-emerald-400 hover:text-emerald-300">
              最小: $50
            </button>
            <button className="text-slate-400 hover:text-white">
              最大: $10,000
            </button>
          </div>
        </div>

        <div className="bg-slate-900/50 rounded-lg p-4 space-y-2">
          <div className="flex justify-between text-sm">
            <span className="text-slate-400">手續費</span>
            <span className="text-white">1%</span>
          </div>
          <div className="flex justify-between text-sm">
            <span className="text-slate-400">Gas 費用</span>
            <span className="text-emerald-400">協議代付</span>
          </div>
        </div>

        <button
          onClick={onDeposit}
          className="w-full py-4 bg-emerald-500 hover:bg-emerald-600 text-white font-semibold rounded-xl transition-all"
        >
          確認存入
        </button>

        <p className="text-xs text-slate-500 text-center">
          存入後，您的 USDC 將自動存入 Navi Protocol 產生收益
        </p>
      </div>
    </div>
  );
}
