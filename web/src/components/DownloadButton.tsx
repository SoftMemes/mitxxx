"use client";
import { useState, useEffect } from "react";
import { getDb } from "@/lib/cache/db";

interface Props {
  blockId: string;
  mp4Url: string | null;
}

export default function DownloadButton({ blockId, mp4Url }: Props) {
  const [status, setStatus] = useState<"idle" | "downloading" | "done" | "error">("idle");
  const [progress, setProgress] = useState(0);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function checkExisting() {
      const db = getDb();
      const dl = await db.downloads.get(blockId);
      if (dl) setStatus("done");
    }
    checkExisting();
  }, [blockId]);

  async function handleDownload() {
    if (!mp4Url || status === "downloading") return;
    setStatus("downloading");
    setProgress(0);
    setError(null);

    try {
      const res = await fetch(mp4Url);
      if (!res.ok) throw new Error(`HTTP ${res.status}`);

      const total = Number(res.headers.get("content-length") ?? 0);
      const reader = res.body!.getReader();
      const chunks: Uint8Array[] = [];
      let received = 0;

      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        chunks.push(value);
        received += value.length;
        if (total > 0) setProgress(Math.round((received / total) * 100));
      }

      const blob = new Blob(chunks as BlobPart[], { type: "video/mp4" });
      const db = getDb();
      await db.downloads.put({
        blockId,
        blob,
        filename: `${blockId.slice(-12)}.mp4`,
        sizeBytes: blob.size,
        downloadedAt: Date.now(),
      });

      setStatus("done");
    } catch (e) {
      setError(String(e));
      setStatus("error");
    }
  }

  async function handleDelete() {
    const db = getDb();
    await db.downloads.delete(blockId);
    setStatus("idle");
    setProgress(0);
  }

  if (status === "done") {
    return (
      <div className="flex items-center gap-3">
        <span className="text-xs text-green-600 font-medium">Saved offline</span>
        <button
          onClick={handleDelete}
          className="text-xs text-gray-400 hover:text-red-500 underline"
        >
          Remove
        </button>
      </div>
    );
  }

  if (status === "downloading") {
    return (
      <div className="space-y-1">
        <div className="h-1.5 bg-gray-200 rounded-full overflow-hidden w-48">
          <div
            className="h-full bg-[#8a1c1c] transition-all"
            style={{ width: `${progress}%` }}
          />
        </div>
        <p className="text-xs text-gray-500">{progress}% downloading…</p>
      </div>
    );
  }

  return (
    <div>
      <button
        onClick={handleDownload}
        disabled={!mp4Url}
        className="text-xs bg-gray-100 hover:bg-gray-200 text-gray-700 px-3 py-1.5 rounded font-medium disabled:opacity-40"
      >
        Download for offline
      </button>
      {error && <p className="text-xs text-red-500 mt-1">{error}</p>}
    </div>
  );
}
