import type { NextRequest } from "next/server";
import { getSessionFromRequest, persistSession } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { LMS_BASE } from "@/lib/proxy/constants";
import { extractVideoMetadata, extractVideoBlockId } from "@/lib/proxy/xblock-parser";
import type { XBlockContent } from "@/lib/types";

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
  const rawVideos = extractVideoMetadata(html);

  const content: XBlockContent = {
    hasContent: rawVideos.length > 0,
    videos: rawVideos.map((v) => ({
      videoBlockId: extractVideoBlockId(v),
      sources: {
        mp4: v.sources.find((s) => s.endsWith(".mp4")) ?? null,
        hls: v.sources.find((s) => s.endsWith(".m3u8")) ?? null,
      },
      duration: v.duration,
      transcriptLanguages: v.transcriptLanguages,
      transcriptTranslationUrl: v.transcriptTranslationUrl,
    })),
  };

  return Response.json(content);
}
