"use client";
import { useEffect, useState } from "react";
import { useRouter, useParams } from "next/navigation";
import Link from "next/link";
import NavBar from "@/components/NavBar";
import { api } from "@/lib/api-client";
import type { CourseOutline, Section } from "@/lib/types";

function SectionItem({ section, courseId }: { section: Section; courseId: string }) {
  const [open, setOpen] = useState(false);
  return (
    <div className="border rounded-lg overflow-hidden">
      <button
        onClick={() => setOpen(!open)}
        className="w-full flex items-center justify-between px-4 py-3 text-left hover:bg-gray-50 font-medium text-sm"
      >
        <span>{section.title}</span>
        <span className="text-gray-400 text-xs">{section.sequence_ids.length} sequences {open ? "▲" : "▼"}</span>
      </button>
      {open && (
        <div className="border-t divide-y bg-white">
          {section.sequence_ids.map((seqId) => (
            <Link
              key={seqId}
              href={`/course/${encodeURIComponent(courseId)}/sequence/${encodeURIComponent(seqId)}`}
              className="block px-6 py-2.5 text-sm hover:bg-gray-50 text-gray-700 hover:text-[#8a1c1c] font-mono truncate"
            >
              {seqId.split("@").pop()}
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

export default function CoursePage() {
  const router = useRouter();
  const { courseId } = useParams<{ courseId: string }>();
  const [outline, setOutline] = useState<CourseOutline | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!courseId) return;
    api.courses.outline(decodeURIComponent(courseId))
      .then(setOutline)
      .catch((e) => {
        if (e.status === 401) router.push("/");
        else setError(String(e));
      })
      .finally(() => setLoading(false));
  }, [courseId, router]);

  return (
    <div className="flex flex-col min-h-screen">
      <NavBar />
      <main className="flex-1 max-w-3xl w-full mx-auto px-6 py-10">
        <Link href="/dashboard" className="text-xs text-gray-400 hover:underline mb-4 inline-block">
          ← My Courses
        </Link>
        {loading && <p className="text-gray-500 text-sm mt-4">Loading outline…</p>}
        {error && <p className="text-red-600 text-sm mt-4">{error}</p>}
        {outline && (
          <>
            <h1 className="text-xl font-bold mb-1">{outline.title}</h1>
            <p className="text-sm text-gray-400 mb-6">
              {new Date(outline.course_start).toLocaleDateString()} –{" "}
              {outline.course_end ? new Date(outline.course_end).toLocaleDateString() : "?"}
            </p>
            <div className="space-y-3">
              {outline.outline.sections.map((section) => (
                <SectionItem
                  key={section.id}
                  section={section}
                  courseId={decodeURIComponent(courseId)}
                />
              ))}
            </div>
          </>
        )}
      </main>
    </div>
  );
}
