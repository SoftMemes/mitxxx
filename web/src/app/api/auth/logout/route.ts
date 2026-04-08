import { cookies } from "next/headers";
import { deleteSession } from "@/lib/session/store";
import { SESSION_COOKIE } from "@/lib/session/middleware";

export async function POST() {
  const cookieStore = await cookies();
  const sessionId = cookieStore.get(SESSION_COOKIE)?.value;
  if (sessionId) {
    deleteSession(sessionId);
  }
  cookieStore.delete(SESSION_COOKIE);
  return Response.json({ ok: true });
}
