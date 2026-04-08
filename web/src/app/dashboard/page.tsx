"use client";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";
import NavBar from "@/components/NavBar";
import CourseCard from "@/components/CourseCard";
import { api } from "@/lib/api-client";
import type { Enrollment } from "@/lib/types";

export default function DashboardPage() {
  const router = useRouter();
  const [enrollments, setEnrollments] = useState<Enrollment[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api.enrollments()
      .then(setEnrollments)
      .catch((e) => {
        if (e.status === 401) router.push("/");
        else setError(String(e));
      })
      .finally(() => setLoading(false));
  }, [router]);

  return (
    <div className="flex flex-col min-h-screen">
      <NavBar />
      <main className="flex-1 max-w-3xl w-full mx-auto px-6 py-10">
        <h1 className="text-xl font-bold mb-6">My Courses</h1>
        {loading && <p className="text-gray-500 text-sm">Loading…</p>}
        {error && <p className="text-red-600 text-sm">{error}</p>}
        {!loading && enrollments.length === 0 && (
          <p className="text-gray-500 text-sm">No enrollments found.</p>
        )}
        <div className="grid gap-4">
          {enrollments.map((enr) => (
            <CourseCard key={enr.id} enrollment={enr} />
          ))}
        </div>
      </main>
    </div>
  );
}
