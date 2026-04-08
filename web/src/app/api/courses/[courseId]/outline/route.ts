import type { NextRequest } from "next/server";
import { getSessionFromRequest, persistSession } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { LMS_BASE } from "@/lib/proxy/constants";

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ courseId: string }> }
) {
  const { courseId } = await params;
  const { sessionId, jar } = await getSessionFromRequest();
  if (!jar || !sessionId) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const r = await fetchWithJar(
    `${LMS_BASE}/api/learning_sequences/v1/course_outline/${encodeURIComponent(courseId)}`,
    jar
  );
  persistSession(sessionId, jar);
  return Response.json(await r.json());
}
