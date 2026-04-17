"use client";
import Dexie, { type Table } from "dexie";
import type { CourseOutline, SequenceDetail, XBlockContent, TranscriptData, Enrollment } from "../types";

interface CachedEnrollments {
  key: "enrollments";
  data: Enrollment[];
  cachedAt: number;
}

interface CachedOutline {
  courseId: string;
  data: CourseOutline;
  cachedAt: number;
}

interface CachedSequence {
  blockId: string;
  data: SequenceDetail;
  cachedAt: number;
}

interface CachedXBlock {
  blockId: string;
  data: XBlockContent;
  cachedAt: number;
}

interface CachedTranscript {
  key: string; // `${courseId}:${videoBlockId}:${lang}`
  data: TranscriptData;
  cachedAt: number;
}

export interface DownloadedVideo {
  blockId: string;
  blob: Blob;
  filename: string;
  sizeBytes: number;
  downloadedAt: number;
}

class MitxDB extends Dexie {
  enrollments!: Table<CachedEnrollments, string>;
  outlines!: Table<CachedOutline, string>;
  sequences!: Table<CachedSequence, string>;
  xblocks!: Table<CachedXBlock, string>;
  transcripts!: Table<CachedTranscript, string>;
  downloads!: Table<DownloadedVideo, string>;

  constructor() {
    super("mitx-offline");
    this.version(1).stores({
      enrollments: "key",
      outlines: "courseId, cachedAt",
      sequences: "blockId, cachedAt",
      xblocks: "blockId, cachedAt",
      transcripts: "key",
      downloads: "blockId, downloadedAt",
    });
  }
}

// Singleton — safe to call multiple times
let _db: MitxDB | null = null;
export function getDb(): MitxDB {
  if (!_db) _db = new MitxDB();
  return _db;
}

const CACHE_TTL_MS = 30 * 60 * 1000; // 30 minutes

export function isStale(cachedAt: number): boolean {
  return Date.now() - cachedAt > CACHE_TTL_MS;
}
