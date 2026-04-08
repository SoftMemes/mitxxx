import { type NextRequest } from "next/server";
import { cookies } from "next/headers";
import { createSession, saveSession } from "@/lib/session/store";
import { login, AuthError } from "@/lib/proxy/auth";
import { SESSION_COOKIE } from "@/lib/session/middleware";

export async function POST(request: NextRequest) {
  const body = await request.json() as { email?: string; password?: string };
  const { email, password } = body;

  if (!email || !password) {
    return Response.json({ error: "email and password required" }, { status: 400 });
  }

  const { sessionId, jar } = createSession();

  try {
    const user = await login(jar, email, password);
    saveSession(sessionId, jar);

    const cookieStore = await cookies();
    cookieStore.set(SESSION_COOKIE, sessionId, {
      httpOnly: true,
      secure: process.env.NODE_ENV === "production",
      sameSite: "lax",
      path: "/",
      maxAge: 60 * 60 * 24 * 14, // 14 days
    });

    return Response.json({ user });
  } catch (e) {
    if (e instanceof AuthError) {
      return Response.json({ error: e.message }, { status: 401 });
    }
    console.error("Login error:", e);
    return Response.json({ error: "Login failed" }, { status: 500 });
  }
}
