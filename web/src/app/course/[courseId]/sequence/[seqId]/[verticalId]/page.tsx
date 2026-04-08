"use client";
import { useEffect, useState } from "react";
import { useRouter, useParams } from "next/navigation";
import Link from "next/link";
import NavBar from "@/components/NavBar";
import VideoPlayer from "@/components/VideoPlayer";
import TranscriptViewer from "@/components/TranscriptViewer";
import DownloadButton from "@/components/DownloadButton";
import { api } from "@/lib/api-client";
import type { XBlockContent, ParsedVideoBlock, TranscriptData } from "@/lib/types";

function VideoSection({
  video,
  courseId,
}: {
  video: ParsedVideoBlock;
  courseId: string;
}) {
  const [transcript, setTranscript] = useState<TranscriptData | null>(null);
  const [transcriptError, setTranscriptError] = useState<string | null>(null);
  const [showTranscript, setShowTranscript] = useState(false);

  async function loadTranscript() {
    if (!video.videoBlockId || transcript) {
      setShowTranscript((v) => !v);
      return;
    }
    try {
      const data = await api.transcripts.get(courseId, video.videoBlockId);
      setTranscript(data);
      setShowTranscript(true);
    } catch (e) {
      setTranscriptError(String(e));
      setShowTranscript(true);
    }
  }

  return (
    <div className="space-y-4">
      <VideoPlayer
        blockId={video.videoBlockId ?? "unknown"}
        mp4Url={video.sources.mp4}
        hlsUrl={video.sources.hls}
        duration={video.duration}
      />
      <div className="flex items-center gap-4 flex-wrap">
        <DownloadButton
          blockId={video.videoBlockId ?? "unknown"}
          mp4Url={video.sources.mp4}
        />
        {video.videoBlockId && (
          <button
            onClick={loadTranscript}
            className="text-xs text-gray-500 hover:text-[#8a1c1c] underline"
          >
            {showTranscript ? "Hide transcript" : "Show transcript"}
          </button>
        )}
      </div>
      {showTranscript && transcriptError && (
        <p className="text-xs text-red-500">{transcriptError}</p>
      )}
      {showTranscript && transcript && <TranscriptViewer data={transcript} />}
    </div>
  );
}

export default function VerticalPage() {
  const router = useRouter();
  const { courseId, seqId, verticalId } = useParams<{
    courseId: string;
    seqId: string;
    verticalId: string;
  }>();
  const [content, setContent] = useState<XBlockContent | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!verticalId) return;
    api.xblocks
      .get(decodeURIComponent(verticalId))
      .then(setContent)
      .catch((e) => {
        if (e.status === 401) router.push("/");
        else setError(String(e));
      })
      .finally(() => setLoading(false));
  }, [verticalId, router]);

  const decodedCourseId = courseId ? decodeURIComponent(courseId) : "";
  const decodedSeqId = seqId ? decodeURIComponent(seqId) : "";

  return (
    <div className="flex flex-col min-h-screen">
      <NavBar />
      <main className="flex-1 max-w-3xl w-full mx-auto px-6 py-10">
        <Link
          href={`/course/${encodeURIComponent(decodedCourseId)}/sequence/${encodeURIComponent(decodedSeqId)}`}
          className="text-xs text-gray-400 hover:underline mb-6 inline-block"
        >
          ← Back to sequence
        </Link>
        {loading && <p className="text-gray-500 text-sm">Loading content…</p>}
        {error && <p className="text-red-600 text-sm">{error}</p>}
        {content && !content.hasContent && (
          <p className="text-gray-500 text-sm">No video content in this block.</p>
        )}
        {content && content.videos.length > 0 && (
          <div className="space-y-10">
            {content.videos.map((video, idx) => (
              <VideoSection
                key={video.videoBlockId ?? idx}
                video={video}
                courseId={decodedCourseId}
              />
            ))}
          </div>
        )}
      </main>
    </div>
  );
}
