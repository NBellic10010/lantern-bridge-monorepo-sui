'use client';

export default function YieldDisplay() {
  return (
    <div className="bg-slate-800 rounded-2xl p-6 border border-slate-700">
      <h2 className="text-xl font-semibold text-white mb-4">
        💵 您的資產
      </h2>

      <div className="space-y-6">
        <div className="text-center py-4">
          <div className="text-slate-400 text-sm mb-2">總資產價值</div>
          <div className="text-4xl font-bold text-white">$1,052.30</div>
          <div className="text-emerald-400 text-sm mt-2">
            +$52.30 (5.23% APY)
          </div>
        </div>

        <div className="border-t border-slate-700 pt-4 space-y-3">
          <div className="flex justify-between items-center">
            <span className="text-slate-400">本金</span>
            <span className="text-white font-mono">$1,000.00</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-slate-400">累積收益</span>
            <span className="text-emerald-400 font-mono">+$52.30</span>
          </div>
          <div className="flex justify-between items-center">
            <span className="text-slate-400">持有份額</span>
            <span className="text-white font-mono">1,000 LS</span>
          </div>
        </div>

        <div className="bg-slate-900/50 rounded-lg p-4">
          <div className="text-sm text-slate-400 mb-2">存款進度</div>
          <div className="h-2 bg-slate-700 rounded-full overflow-hidden">
            <div
              className="h-full bg-gradient-to-r from-emerald-500 to-emerald-400 rounded-full"
              style={{ width: '100%' }}
            />
          </div>
          <div className="flex justify-between text-xs text-slate-500 mt-2">
            <span>$0</span>
            <span>$1,052.30 / $1,000</span>
          </div>
        </div>
      </div>
    </div>
  );
}
