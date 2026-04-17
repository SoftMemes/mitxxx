/**
 * 3-stage MITx authentication flow.
 * Direct port of client.py's login() + _lms_oauth() methods.
 *
 * Stage 1: GET mitxonline/login/ → Keycloak SPA
 * Stage 2a: POST username → Keycloak (step 1 of 2-step login)
 * Stage 2b: POST password → Keycloak (step 2) → redirects to mitxonline
 * Stage 3: GET courses.learn.mit.edu/auth/login/ol-oauth2/ → LMS JWT cookies
 */
import { CookieJar } from "tough-cookie";
import { fetchWithJar } from "./fetch-with-jar";
import { MITXONLINE_BASE, LMS_BASE } from "./constants";

export class AuthError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "AuthError";
  }
}

function extractKcLoginAction(html: string): string {
  // The Keycloak login page is a JS SPA — the form action URL is embedded
  // in a kcContext JS object as url.loginAction.
  const match = html.match(/"loginAction":\s*"(https:\/\/[^"]+)"/);
  if (!match) {
    throw new AuthError(
      "Could not find Keycloak loginAction URL in page. The login page may have changed."
    );
  }
  // Keycloak JSON-escapes forward slashes as \/
  return match[1].replace(/\\\//g, "/");
}

export async function login(
  jar: CookieJar,
  email: string,
  password: string
): Promise<object> {
  // Stage 1: Follow redirect chain to Keycloak SPA
  const r1 = await fetchWithJar(`${MITXONLINE_BASE}/login/`, jar);
  const html1 = await r1.text();
  const actionUrl1 = extractKcLoginAction(html1);

  // Stage 2a: POST username
  const r2 = await fetchWithJar(actionUrl1, jar, {
    method: "POST",
    body: new URLSearchParams({ username: email }),
  });
  if (r2.status !== 200) {
    throw new AuthError(`Keycloak username step failed (${r2.status})`);
  }
  const html2 = await r2.text();
  const actionUrl2 = extractKcLoginAction(html2);

  // Stage 2b: POST password
  const r3 = await fetchWithJar(actionUrl2, jar, {
    method: "POST",
    body: new URLSearchParams({ password, credentialId: "" }),
  });
  if (![200, 302].includes(r3.status)) {
    throw new AuthError(`Keycloak password step failed (${r3.status})`);
  }

  // Verify mitxonline session
  const r4 = await fetchWithJar(
    `${MITXONLINE_BASE}/api/v0/users/current_user/`,
    jar
  );
  const user = await r4.json() as Record<string, unknown>;
  if (!user.is_authenticated) {
    throw new AuthError("Login failed — user not authenticated after OAuth callback");
  }

  // Stage 3: LMS OAuth2 — get JWT cookies on courses.learn.mit.edu
  await fetchWithJar(
    `${LMS_BASE}/auth/login/ol-oauth2/?auth_entry=login`,
    jar
  );

  return user;
}
