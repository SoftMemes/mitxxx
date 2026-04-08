"use client";
import Link from "next/link";
import type { Enrollment } from "@/lib/types";

export default function CourseCard({ enrollment }: { enrollment: Enrollment }) {
  const { run } = enrollment;
  const end = run.end_date ? new Date(run.end_date).toLocaleDateString() : null;

  return (
    <Link
      href={`/course/${encodeURIComponent(run.courseware_id)}`}
      className="block border rounded-lg p-5 hover:border-[#8a1c1c] hover:shadow-md transition-all bg-white"
    >
      <div className="flex items-start justify-between gap-3">
        <div>
          <h2 className="font-semibold text-base">{run.title}</h2>
          <p className="text-sm text-gray-500 mt-0.5">{run.course_number} · {run.run_tag}</p>
        </div>
        <span className="text-xs bg-gray-100 text-gray-600 px-2 py-1 rounded shrink-0">
          {enrollment.enrollment_mode}
        </span>
      </div>
      {end && (
        <p className="text-xs text-gray-400 mt-3">Ended {end}</p>
      )}
    </Link>
  );
}
