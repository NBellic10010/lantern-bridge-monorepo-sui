'use client';

import Link from 'next/link';
import { useWallet } from '@mysten/dapp-kit';

export default function Header() {
  const { currentAccount, disconnect } = useWallet();

  return (
    <header className="bg-slate-900/80 backdrop-blur-md border-b border-slate-700">
      <div className="container mx-auto px-4 py-4">
        <div className="flex items-center justify-between">
          {/* Logo */}
          <Link href="/" className="flex items-center space-x-2">
            <span className="text-2xl">🏮</span>
            <span className="text-xl font-bold text-white">Lantern</span>
            <span className="px-2 py-0.5 text-xs bg-emerald-500/20 text-emerald-400 rounded">
              V1.0
            </span>
          </Link>

          {/* Navigation */}
          <nav className="hidden md:flex items-center space-x-6">
            <Link href="/" className="text-slate-300 hover:text-white transition">
              存入
            </Link>
            <Link href="#" className="text-slate-300 hover:text-white transition">
              收益
            </Link>
            <Link href="#" className="text-slate-300 hover:text-white transition">
              關於
            </Link>
          </nav>

          {/* Wallet Connect */}
          <div>
            {currentAccount ? (
              <button
                onClick={() => disconnect()}
                className="px-4 py-2 bg-slate-700 hover:bg-slate-600 text-white rounded-lg transition"
              >
                {currentAccount.address.slice(0, 6)}...{currentAccount.address.slice(-4)}
              </button>
            ) : (
              <button className="px-4 py-2 bg-emerald-500 hover:bg-emerald-600 text-white rounded-lg transition">
                連接錢包
              </button>
            )}
          </div>
        </div>
      </div>
    </header>
  );
}
