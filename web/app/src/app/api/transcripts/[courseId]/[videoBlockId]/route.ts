import type { NextRequest } from "next/server";
import { getSessionFromRequest, persistSession } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { LMS_BASE } from "@/lib/proxy/constants";

export async function GET(
  req: NextRequest,
  { params }: { params: Promise<{ courseId: string; videoBlockId: string }> }
) {
  const { courseId, videoBlockId } = await params;
  const lang = req.nextUrl.searchParams.get("lang") ?? "en";

  const { sessionId, jar } = await getSessionFromRequest();
  if (!jar || !sessionId) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const url =
    `${LMS_BASE}/courses/${encodeURIComponent(courseId)}` +
    `/xblock/${encodeURIComponent(videoBlockId)}` +
    `/handler/transcript/translation/${lang}`;

  const r = await fetchWithJar(url, jar);
  persistSession(sessionId, jar);
  return Response.json(await r.json());
}
