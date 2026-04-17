import type { NextRequest } from "next/server";
import { getSessionFromRequest, persistSession } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { LMS_BASE } from "@/lib/proxy/constants";
import { extractVideoMetadata } from "@/lib/proxy/xblock-parser";

export async function GET(
  _req: NextRequest,
  { params }: { params: Promise<{ blockId: string }> }
) {
  const { blockId } = await params;
  const { sessionId, jar } = await getSessionFromRequest();
  if (!jar || !sessionId) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const r = await fetchWithJar(
    `${LMS_BASE}/xblock/${encodeURIComponent(blockId)}`,
    jar
  );
  persistSession(sessionId, jar);

  const html = await r.text();
  const videos = extractVideoMetadata(html);
  const first = videos[0];

  if (!first) {
    return Response.json({ mp4: null, hls: null });
  }

  return Response.json({
    mp4: first.sources.find((s: string) => s.endsWith(".mp4")) ?? null,
    hls: first.sources.find((s: string) => s.endsWith(".m3u8")) ?? null,
  });
}
