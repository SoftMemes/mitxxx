/**
 * Browser-side typed fetch wrappers for all /api/* routes.
 */
import type {
  User,
  Enrollment,
  CourseOutline,
  SequenceDetail,
  XBlockContent,
  TranscriptData,
} from "./types";

async function apiFetch<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(path, { credentials: "include", ...options });
  if (!res.ok) {
    const err = await res.json().catch(() => ({ error: res.statusText }));
    throw Object.assign(new Error((err as { error: string }).error ?? res.statusText), {
      status: res.status,
    });
  }
  return res.json() as Promise<T>;
}

export const api = {
  auth: {
    login: (email: string, password: string) =>
      apiFetch<{ user: User }>("/api/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ email, password }),
      }),
    logout: () => apiFetch<void>("/api/auth/logout", { method: "POST" }),
    me: () => apiFetch<User>("/api/auth/me"),
  },

  enrollments: () => apiFetch<Enrollment[]>("/api/enrollments"),

  courses: {
    outline: (courseId: string) =>
      apiFetch<CourseOutline>(`/api/courses/${encodeURIComponent(courseId)}/outline`),
    metadata: (courseId: string) =>
      apiFetch<object>(`/api/courses/${encodeURIComponent(courseId)}/metadata`),
  },

  sequences: {
    get: (blockId: string) =>
      apiFetch<SequenceDetail>(`/api/sequences/${encodeURIComponent(blockId)}`),
  },

  xblocks: {
    get: (blockId: string) =>
      apiFetch<XBlockContent>(`/api/xblocks/${encodeURIComponent(blockId)}`),
  },

  transcripts: {
    get: (courseId: string, videoBlockId: string, lang = "en") =>
      apiFetch<TranscriptData>(
        `/api/transcripts/${encodeURIComponent(courseId)}/${encodeURIComponent(videoBlockId)}?lang=${lang}`
      ),
  },

  videoUrl: {
    get: (blockId: string) =>
      apiFetch<{ mp4: string | null; hls: string | null }>(
        `/api/video-url/${encodeURIComponent(blockId)}`
      ),
  },
};
