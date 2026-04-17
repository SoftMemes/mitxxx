"use client";
import { useState, useEffect } from "react";
import { getDb, isStale } from "./db";
import type { Table } from "dexie";

export function useOfflineStatus(): boolean {
  const [offline, setOffline] = useState(false);
  useEffect(() => {
    setOffline(!navigator.onLine);
    const on = () => setOffline(false);
    const off = () => setOffline(true);
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
    };
  }, []);
  return offline;
}

interface CacheEntry {
  cachedAt: number;
  [key: string]: unknown;
}

export function useCachedQuery<T extends CacheEntry>(
  cacheKey: string,
  table: Table<T, string>,
  fetcher: () => Promise<T["data"] extends infer D ? D : unknown>,
  options?: { enabled?: boolean }
): { data: T | null; loading: boolean; error: string | null; refresh: () => void } {
  const [data, setData] = useState<T | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [tick, setTick] = useState(0);
  const enabled = options?.enabled ?? true;

  useEffect(() => {
    if (!enabled) return;
    let cancelled = false;

    async function load() {
      setLoading(true);
      setError(null);
      try {
        // Try cache first
        const cached = await table.get(cacheKey);
        if (cached && !isStale(cached.cachedAt)) {
          if (!cancelled) { setData(cached); setLoading(false); }
          return;
        }

        // Fetch fresh data if online
        if (navigator.onLine) {
          const fresh = await (fetcher as () => Promise<unknown>)();
          const entry = { ...(cached ?? {}), data: fresh, cachedAt: Date.now() } as unknown as T;
          // The key field is set by the table definition
          await table.put(entry);
          if (!cancelled) { setData(entry); setLoading(false); }
        } else if (cached) {
          // Offline with stale cache — use it anyway
          if (!cancelled) { setData(cached); setLoading(false); }
        } else {
          if (!cancelled) { setError("No cached data and offline"); setLoading(false); }
        }
      } catch (e) {
        if (!cancelled) { setError(String(e)); setLoading(false); }
      }
    }

    load();
    return () => { cancelled = true; };
  }, [cacheKey, enabled, tick]); // eslint-disable-line react-hooks/exhaustive-deps

  return { data, loading, error, refresh: () => setTick(t => t + 1) };
}
