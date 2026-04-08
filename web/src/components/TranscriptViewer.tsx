"use client";
import type { TranscriptData } from "@/lib/types";

function formatTime(ms: number): string {
  const s = Math.floor(ms / 1000);
  const m = Math.floor(s / 60);
  const sec = s % 60;
  return `${m}:${String(sec).padStart(2, "0")}`;
}

export default function TranscriptViewer({ data }: { data: TranscriptData }) {
  const lines = data.text.filter((t) => t.trim());

  return (
    <div className="bg-gray-50 border rounded-lg p-4 max-h-80 overflow-y-auto text-sm space-y-2">
      {lines.map((text, i) => (
        <div key={i} className="flex gap-3 items-start">
          <span className="text-gray-400 shrink-0 font-mono text-xs pt-0.5">
            {formatTime(data.start[i])}
          </span>
          <p className="text-gray-800">{text}</p>
        </div>
      ))}
    </div>
  );
}
