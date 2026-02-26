import { Providers } from './providers';
import Dashboard from '@/components/Dashboard';

export default function Home() {
  return (
    <Providers>
      <main className="min-h-screen bg-gradient-to-b from-slate-900 to-slate-800">
        <Dashboard />
      </main>
    </Providers>
  );
}
