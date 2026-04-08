"use client";
import { useEffect, useState } from "react";
import { useRouter, useParams } from "next/navigation";
import Link from "next/link";
import NavBar from "@/components/NavBar";
import { api } from "@/lib/api-client";
import type { SequenceDetail, SequenceItem } from "@/lib/types";

const TYPE_BADGE: Record<SequenceItem["type"], string> = {
  video: "bg-blue-100 text-blue-700",
  problem: "bg-yellow-100 text-yellow-700",
  other: "bg-gray-100 text-gray-600",
};

export default function SequencePage() {
  const router = useRouter();
  const { courseId, seqId } = useParams<{ courseId: string; seqId: string }>();
  const [detail, setDetail] = useState<SequenceDetail | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!seqId) return;
    api.sequences
      .get(decodeURIComponent(seqId))
      .then(setDetail)
      .catch((e) => {
        if (e.status === 401) router.push("/");
        else setError(String(e));
      })
      .finally(() => setLoading(false));
  }, [seqId, router]);

  const decodedCourseId = courseId ? decodeURIComponent(courseId) : "";
  const decodedSeqId = seqId ? decodeURIComponent(seqId) : "";

  return (
    <div className="flex flex-col min-h-screen">
      <NavBar />
      <main className="flex-1 max-w-3xl w-full mx-auto px-6 py-10">
        <Link
          href={`/course/${encodeURIComponent(decodedCourseId)}`}
          className="text-xs text-gray-400 hover:underline mb-4 inline-block"
        >
          ← Course Outline
        </Link>
        <p className="text-xs text-gray-400 font-mono mb-6 truncate">{decodedSeqId.split("@").pop()}</p>
        {loading && <p className="text-gray-500 text-sm">Loading sequence…</p>}
        {error && <p className="text-red-600 text-sm">{error}</p>}
        {detail && (
          <div className="space-y-2">
            {detail.items.length === 0 && (
              <p className="text-gray-500 text-sm">No items in this sequence.</p>
            )}
            {detail.items.map((item, idx) => (
              <Link
                key={item.id}
                href={`/course/${encodeURIComponent(decodedCourseId)}/sequence/${encodeURIComponent(decodedSeqId)}/${encodeURIComponent(item.id)}`}
                className="flex items-center gap-3 border rounded-lg px-4 py-3 hover:bg-gray-50 group"
              >
                <span className="text-gray-400 text-xs w-5 shrink-0">{idx + 1}</span>
                <span
                  className={`text-xs px-2 py-0.5 rounded font-medium shrink-0 ${TYPE_BADGE[item.type]}`}
                >
                  {item.type}
                </span>
                <span className="text-sm text-gray-800 group-hover:text-[#8a1c1c] truncate flex-1">
                  {item.page_title || item.id.split("@").pop()}
                </span>
                {item.complete && (
                  <span className="text-green-500 text-xs shrink-0">✓</span>
                )}
              </Link>
            ))}
          </div>
        )}
      </main>
    </div>
  );
}
