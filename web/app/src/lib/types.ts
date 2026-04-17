export interface User {
  id: number;
  username: string;
  name: string;
  email: string;
  is_authenticated: boolean;
  is_anonymous: boolean;
}

export interface CourseRun {
  title: string;
  courseware_id: string;
  courseware_url: string;
  start_date: string;
  end_date: string | null;
  run_tag: string;
  course_number: string;
}

export interface Enrollment {
  id: number;
  enrollment_mode: "audit" | "verified";
  run: CourseRun;
}

export interface Section {
  id: string;
  title: string;
  sequence_ids: string[];
  start: string;
  effective_start: string;
}

export interface CourseOutline {
  course_key: string;
  title: string;
  course_start: string;
  course_end: string;
  outline: {
    sections: Section[];
  };
}

export interface SequenceItem {
  id: string;
  type: "video" | "problem" | "other";
  page_title: string;
  complete: boolean;
  bookmarked: boolean;
  path: string;
}

export interface SequenceDetail {
  items: SequenceItem[];
}

export interface VideoSource {
  mp4: string | null;
  hls: string | null;
}

export interface ParsedVideoBlock {
  videoBlockId: string | null;
  sources: VideoSource;
  duration: number;
  transcriptLanguages: Record<string, string>;
  transcriptTranslationUrl: string;
}

export interface XBlockContent {
  videos: ParsedVideoBlock[];
  hasContent: boolean;
}

export interface TranscriptData {
  start: number[];
  end: number[];
  text: string[];
}
