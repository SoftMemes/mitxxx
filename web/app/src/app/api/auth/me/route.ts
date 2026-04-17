import { getSessionFromRequest } from "@/lib/session/middleware";
import { fetchWithJar } from "@/lib/proxy/fetch-with-jar";
import { MITXONLINE_BASE } from "@/lib/proxy/constants";

export async function GET() {
  const { jar } = await getSessionFromRequest();
  if (!jar) {
    return Response.json({ error: "Not authenticated" }, { status: 401 });
  }

  const r = await fetchWithJar(`${MITXONLINE_BASE}/api/v0/users/current_user/`, jar);
  const user = await r.json() as Record<string, unknown>;

  if (!user.is_authenticated) {
    return Response.json({ error: "Session expired" }, { status: 401 });
  }

  return Response.json(user);
}
