/**
 * Helpers for reading/writing the mitx_sid session cookie from/to API routes.
 */
import { CookieJar } from "tough-cookie";
import { cookies } from "next/headers";
import { getSession, saveSession, deleteSession } from "./store";

export const SESSION_COOKIE = "mitx_sid";

export async function getSessionFromRequest(): Promise<{
  sessionId: string | null;
  jar: CookieJar | null;
}> {
  const cookieStore = await cookies();
  const sessionId = cookieStore.get(SESSION_COOKIE)?.value ?? null;
  if (!sessionId) return { sessionId: null, jar: null };
  const jar = getSession(sessionId);
  return { sessionId, jar };
}

export function persistSession(sessionId: string, jar: CookieJar): void {
  saveSession(sessionId, jar);
}

export function removeSession(sessionId: string): void {
  deleteSession(sessionId);
}
