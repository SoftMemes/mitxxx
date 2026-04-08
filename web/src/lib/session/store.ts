/**
 * Server-side session store.
 * Maps session IDs (UUID) to serialized tough-cookie CookieJars.
 * In-memory — sufficient for single-user personal tool.
 */
import { CookieJar } from "tough-cookie";
import { v4 as uuidv4 } from "uuid";

// Use a module-level Map that persists across requests in the same process
const store = new Map<string, string>();

export function createSession(): { sessionId: string; jar: CookieJar } {
  const sessionId = uuidv4();
  const jar = new CookieJar();
  store.set(sessionId, jar.serializeSync() as unknown as string);
  return { sessionId, jar };
}

export function getSession(sessionId: string): CookieJar | null {
  const serialized = store.get(sessionId);
  if (!serialized) return null;
  try {
    return CookieJar.deserializeSync(serialized as unknown as Parameters<typeof CookieJar.deserializeSync>[0]);
  } catch {
    return null;
  }
}

export function saveSession(sessionId: string, jar: CookieJar): void {
  store.set(sessionId, jar.serializeSync() as unknown as string);
}

export function deleteSession(sessionId: string): void {
  store.delete(sessionId);
}
