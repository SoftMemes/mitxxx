"use client";
import { useEffect, useState, useRef } from "react";
import { getDb } from "@/lib/cache/db";

interface Props {
  blockId: string;
  mp4Url: string | null;
  hlsUrl: string | null;
  duration: number;
}

export default function VideoPlayer({ blockId, mp4Url, duration }: Props) {
  const [src, setSrc] = useState<string | null>(mp4Url);
  const [isDownloaded, setIsDownloaded] = useState(false);
  const videoRef = useRef<HTMLVideoElement>(null);

  useEffect(() => {
    async function checkDownload() {
      const db = getDb();
      const dl = await db.downloads.get(blockId);
      if (dl) {
        setSrc(URL.createObjectURL(dl.blob));
        setIsDownloaded(true);
      }
    }
    checkDownload();
  }, [blockId]);

  if (!src) {
    return (
      <div className="bg-gray-900 rounded-lg aspect-video flex items-center justify-center text-gray-400 text-sm">
        No video available
      </div>
    );
  }

  return (
    <div className="space-y-2">
      {isDownloaded && (
        <div className="text-xs text-green-600 font-medium">
          Playing from local storage (offline copy)
        </div>
      )}
      <video
        ref={videoRef}
        src={src}
        controls
        className="w-full rounded-lg bg-black aspect-video"
        preload="metadata"
      >
        Your browser does not support video playback.
      </video>
      {duration > 0 && (
        <p className="text-xs text-gray-400">{Math.round(duration)}s · {(duration / 60).toFixed(1)} min</p>
      )}
    </div>
  );
}
