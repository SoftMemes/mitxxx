/**
 * Extract video metadata from xblock HTML.
 * Port of client.py's extract_video_metadata().
 */
import * as cheerio from "cheerio";

export interface VideoMetadata {
  sources: string[];
  duration: number;
  transcriptLanguages: Record<string, string>;
  transcriptTranslationUrl: string;
  publishCompletionUrl: string;
  saveStateUrl: string;
  showCaptions: string;
  autoplay: boolean;
}

export function extractVideoMetadata(html: string): VideoMetadata[] {
  const $ = cheerio.load(html);
  const results: VideoMetadata[] = [];

  $("[data-metadata]").each((_, el) => {
    const raw = $(el).attr("data-metadata");
    if (!raw) return;
    try {
      // The attribute is HTML-entity-encoded; cheerio unescapes it for us
      const meta = JSON.parse(raw) as Record<string, unknown>;
      if (Array.isArray(meta.sources) && meta.sources.length > 0) {
        results.push(meta as unknown as VideoMetadata);
      }
    } catch {
      // Skip malformed metadata
    }
  });

  return results;
}

export function extractVideoBlockId(meta: VideoMetadata): string | null {
  // publishCompletionUrl contains the video block ID:
  // /courses/{course_id}/xblock/{video_block_id}/handler/publish_completion
  const match = meta.publishCompletionUrl?.match(/\/xblock\/([^/]+)\/handler/);
  return match ? match[1] : null;
}
