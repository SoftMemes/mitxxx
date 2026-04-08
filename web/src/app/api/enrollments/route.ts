import { getSessionFromRequest, persistSession } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { MITXONLINE_BASE } from "@/lib/proxy/constants";

export async function GET() {
  const { sessionId, jar } = await getSessionFromRequest();
  if (!jar || !sessionId) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const r = await fetchWithJar(`${MITXONLINE_BASE}/api/v1/enrollments/`, jar);
  persistSession(sessionId, jar);
  const data = await r.json();
  return Response.json(data);
}
