"""
MITxClient — unofficial Python client for the MITx / MIT OpenLearning platform.

Reverse-engineered from mitmproxy captures of the MITx mobile/web app.
See CLAUDE.md for protocol details.
"""
import json
import os
import re
import html as html_module
from pathlib import Path
from urllib.parse import urlencode, urlparse, parse_qs

import requests
from bs4 import BeautifulSoup


MITXONLINE_BASE = "https://mitxonline.mit.edu"
LMS_BASE = "https://courses.learn.mit.edu"
SSO_BASE = "https://sso.ol.mit.edu"

SESSION_FILE = Path.home() / ".mitx-client" / "session.json"


class AuthError(Exception):
    pass


class MITxClient:
    def __init__(self):
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": (
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) "
                "AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
            ),
        })

    # -------------------------------------------------------------------------
    # Session persistence
    # -------------------------------------------------------------------------

    def save_session(self):
        SESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
        cookies = {c.name: c.value for c in self.session.cookies}
        SESSION_FILE.write_text(json.dumps(cookies, indent=2))

    def load_session(self) -> bool:
        if not SESSION_FILE.exists():
            return False
        cookies = json.loads(SESSION_FILE.read_text())
        for name, value in cookies.items():
            self.session.cookies.set(name, value)
        return True

    def is_authenticated(self) -> bool:
        try:
            r = self.session.get(f"{MITXONLINE_BASE}/api/v0/users/current_user/", timeout=10)
            if r.status_code == 200:
                data = r.json()
                return data.get("is_authenticated", False)
        except Exception:
            pass
        return False

    # -------------------------------------------------------------------------
    # Authentication — 3-stage OAuth2
    # -------------------------------------------------------------------------

    @staticmethod
    def _extract_kc_login_action(html: str) -> str:
        """
        Keycloak renders a JS SPA — the form action URL is in the kcContext
        JS object as url.loginAction, not in an HTML <form> tag.
        """
        m = re.search(r'"loginAction":\s*"(https://[^"]+)"', html)
        if not m:
            raise AuthError(
                "Could not find Keycloak loginAction in page. "
                "The login page HTML may have changed."
            )
        # Keycloak JSON-escapes forward slashes as \/
        return m.group(1).replace("\\/", "/")

    def login(self, email: str, password: str):
        """
        Perform the full 3-stage auth flow:
          1. mitxonline.mit.edu/login/ → Keycloak SSO redirect (JS SPA)
          2a. POST username to Keycloak (step 1 of 2-step login)
          2b. POST password to new action URL (step 2)
          3. LMS OAuth2 handshake
        """
        # Stage 1: Start login on mitxonline, follow redirect to Keycloak SPA
        r = self.session.get(
            f"{MITXONLINE_BASE}/login/",
            allow_redirects=True,
            timeout=15,
        )
        # Keycloak renders a JS SPA — extract loginAction from kcContext JS object
        action_url = self._extract_kc_login_action(r.text)

        # Stage 2a: POST username only (Keycloak 2-step: username → password)
        r2 = self.session.post(
            action_url,
            data={"username": email},
            allow_redirects=True,
            timeout=15,
        )
        if r2.status_code != 200:
            raise AuthError(f"Keycloak username step failed with status {r2.status_code}")

        # Extract the new loginAction from the password page
        action_url2 = self._extract_kc_login_action(r2.text)

        # Stage 2b: POST password to the new action URL
        r3 = self.session.post(
            action_url2,
            data={"password": password, "credentialId": ""},
            allow_redirects=True,
            timeout=15,
        )
        # Success: Keycloak 302s back through mitxonline; requests follows the chain
        if r3.status_code not in (200, 302):
            raise AuthError(f"Keycloak password step failed with status {r3.status_code}")

        # Verify mitxonline session is established
        r3 = self.session.get(f"{MITXONLINE_BASE}/api/v0/users/current_user/", timeout=10)
        user = r3.json()
        if not user.get("is_authenticated"):
            raise AuthError("mitxonline login failed — user not authenticated after OAuth callback")

        # Stage 3: Establish LMS (Open edX) session via OAuth2
        self._lms_oauth()

        self.save_session()
        return user

    def _lms_oauth(self):
        """Trigger the LMS OAuth2 handshake to get JWT cookies on courses.learn.mit.edu."""
        # The LMS OAuth entry point redirects through mitxonline and back.
        self.session.get(
            f"{LMS_BASE}/auth/login/ol-oauth2/",
            params={"auth_entry": "login"},
            allow_redirects=True,
            timeout=15,
        )
        # After this chain the session should have LMS cookies set.

    # -------------------------------------------------------------------------
    # mitxonline.mit.edu APIs
    # -------------------------------------------------------------------------

    def current_user(self) -> dict:
        r = self.session.get(f"{MITXONLINE_BASE}/api/v0/users/current_user/", timeout=10)
        r.raise_for_status()
        return r.json()

    def enrollments(self) -> list:
        r = self.session.get(f"{MITXONLINE_BASE}/api/v1/enrollments/", timeout=10)
        r.raise_for_status()
        return r.json()

    # -------------------------------------------------------------------------
    # LMS (courses.learn.mit.edu) APIs
    # -------------------------------------------------------------------------

    def _lms_get(self, path: str, **kwargs) -> requests.Response:
        url = f"{LMS_BASE}{path}"
        r = self.session.get(url, timeout=15, **kwargs)
        r.raise_for_status()
        return r

    def course_metadata(self, course_id: str) -> dict:
        return self._lms_get(f"/api/course_home/course_metadata/{course_id}").json()

    def course_outline(self, course_id: str) -> dict:
        """Full course outline with block tree (sections/sequences)."""
        return self._lms_get(f"/api/learning_sequences/v1/course_outline/{course_id}").json()

    def sequence(self, block_id: str) -> dict:
        """Items (verticals) in a sequence with their types (video/problem/other)."""
        return self._lms_get(f"/api/courseware/sequence/{block_id}").json()

    def xblock_html(self, block_id: str) -> str:
        """Raw HTML for a vertical xblock. Contains embedded video metadata."""
        return self._lms_get(f"/xblock/{block_id}").text

    def extract_video_metadata(self, xblock_html: str) -> list[dict]:
        """
        Parse xblock HTML and extract all video metadata objects.
        Returns list of dicts with keys: sources (list of URLs), duration,
        transcriptTranslationUrl, transcriptLanguages, etc.
        """
        soup = BeautifulSoup(xblock_html, "html.parser")
        results = []
        for el in soup.find_all(attrs={"data-metadata": True}):
            raw = el["data-metadata"]
            try:
                meta = json.loads(html_module.unescape(raw))
                if "sources" in meta:
                    results.append(meta)
            except (json.JSONDecodeError, ValueError):
                continue
        return results

    def transcript(self, course_id: str, video_block_id: str, lang: str = "en") -> str:
        """Download transcript text (SRT format) for a video block."""
        path = (
            f"/courses/{course_id}/xblock/{video_block_id}"
            f"/handler/transcript/translation/{lang}"
        )
        return self._lms_get(path).text

    def csrf_token(self) -> str:
        r = self._lms_get("/csrf/api/v1/token")
        return r.json()["csrfToken"]

    # -------------------------------------------------------------------------
    # Video download
    # -------------------------------------------------------------------------

    def download_video(
        self,
        vertical_block_id: str,
        output_dir: str = ".",
        prefer_hls: bool = False,
        progress_callback=None,
    ) -> list[str]:
        """
        Download all videos from a vertical xblock.

        Returns list of downloaded file paths.
        """
        html = self.xblock_html(vertical_block_id)
        videos = self.extract_video_metadata(html)

        if not videos:
            return []

        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)

        downloaded = []
        for i, meta in enumerate(videos):
            sources = meta.get("sources", [])
            if not sources:
                continue

            # Pick MP4 or HLS
            if prefer_hls:
                url = next((s for s in sources if s.endswith(".m3u8")), sources[0])
            else:
                url = next((s for s in sources if s.endswith(".mp4")), sources[0])

            # Derive filename from URL hash
            url_path = urlparse(url).path  # e.g. /transcoded/{hash}/video_custom.mp4
            parts = url_path.strip("/").split("/")
            video_hash = parts[1] if len(parts) >= 2 else f"video_{i}"
            block_short = vertical_block_id.rsplit("@", 1)[-1][:12]
            filename = f"{block_short}_{video_hash[:12]}.mp4"
            dest = output_path / filename

            if dest.exists():
                downloaded.append(str(dest))
                continue

            with self.session.get(url, stream=True, timeout=60) as r:
                r.raise_for_status()
                total = int(r.headers.get("content-length", 0))
                downloaded_bytes = 0
                with open(dest, "wb") as fh:
                    for chunk in r.iter_content(chunk_size=65536):
                        fh.write(chunk)
                        downloaded_bytes += len(chunk)
                        if progress_callback:
                            progress_callback(downloaded_bytes, total, filename)

            downloaded.append(str(dest))

        return downloaded
