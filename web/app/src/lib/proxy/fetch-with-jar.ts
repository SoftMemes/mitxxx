/**
 * Cookie-aware fetch that manually follows redirects, capturing Set-Cookie at
 * each hop. This is essential for the MITx auth flow which spans 3 domains.
 *
 * Node's built-in fetch with redirect:'follow' silently drops Set-Cookie
 * headers at intermediate hops — we must follow redirects ourselves.
 */
import { CookieJar } from "tough-cookie";

const MAX_REDIRECTS = 20;

export interface FetchOptions {
  method?: string;
  headers?: Record<string, string>;
  body?: string | URLSearchParams;
}

export async function fetchWithJar(
  url: string,
  jar: CookieJar,
  options: FetchOptions = {},
  _redirectsLeft = MAX_REDIRECTS
): Promise<Response> {
  if (_redirectsLeft === 0) {
    throw new Error(`Too many redirects fetching ${url}`);
  }

  // Attach cookies from the jar for this URL
  const cookieString = await jar.getCookieString(url);
  const headers: Record<string, string> = { ...options.headers };
  if (cookieString) {
    headers["Cookie"] = cookieString;
  }

  // Build the fetch init — URLSearchParams sets Content-Type automatically
  const init: RequestInit = {
    method: options.method ?? "GET",
    headers,
    redirect: "manual",
  };
  if (options.body !== undefined) {
    init.body = options.body;
  }

  const response = await fetch(url, init);

  // Capture all Set-Cookie headers into the jar
  // response.headers.getSetCookie() returns array of raw Set-Cookie strings
  const setCookies = response.headers.getSetCookie?.() ?? [];
  for (const sc of setCookies) {
    try {
      await jar.setCookie(sc, url);
    } catch {
      // Some cookies have attributes tough-cookie rejects; skip them
    }
  }

  // Follow redirects ourselves (GET only, no body forwarding)
  const status = response.status;
  if ([301, 302, 303, 307, 308].includes(status)) {
    const location = response.headers.get("location");
    if (location) {
      const resolved = new URL(location, url).toString();
      return fetchWithJar(resolved, jar, { method: "GET" }, _redirectsLeft - 1);
    }
  }

  return response;
}
