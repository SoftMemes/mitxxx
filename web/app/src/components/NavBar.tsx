"use client";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { api } from "@/lib/api-client";
import { useOfflineStatus } from "@/lib/cache/hooks";

export default function NavBar() {
  const router = useRouter();
  const offline = useOfflineStatus();

  async function handleLogout() {
    try {
      await api.auth.logout();
    } finally {
      router.push("/");
      router.refresh();
    }
  }

  return (
    <nav className="bg-[#8a1c1c] text-white px-6 py-3 flex items-center gap-6 shadow">
      <Link href="/dashboard" className="font-bold text-lg tracking-tight">
        MITx Offline
      </Link>
      <span className="text-xs opacity-60 italic">unofficial</span>
      <span className="flex-1" />
      {offline && (
        <span className="bg-amber-500 text-black text-xs font-semibold px-2 py-0.5 rounded">
          OFFLINE
        </span>
      )}
      <button
        onClick={handleLogout}
        className="text-sm hover:underline opacity-80 hover:opacity-100"
      >
        Sign out
      </button>
    </nav>
  );
}
