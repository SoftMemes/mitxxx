"""
OcwClient — unofficial Python client for MIT OpenCourseWare (ocw.mit.edu).

OCW is a separate platform from MITx / courses.learn.mit.edu: it is a static,
public content site. No authentication is required. Videos are hosted on
archive.org and exposed via a plain "Download video" link on each lecture page.

See CLAUDE.md for protocol details, URL patterns, and known quirks.
"""
from __future__ import annotations

import json
import re
from dataclasses import dataclass, field, asdict
from enum import Enum
from pathlib import Path
from typing import Optional
from urllib.parse import urljoin

import requests
from bs4 import BeautifulSoup


OCW_BASE = "https://ocw.mit.edu"

_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 13_0) "
    "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/605.1.15"
)


# -----------------------------------------------------------------------------
# Data model
# -----------------------------------------------------------------------------


class OcwResourceType(str, Enum):
    LECTURE_NOTES = "lecture-notes"
    LECTURE_SLIDES = "lecture-slides"


@dataclass
class OcwResource:
    id: str  # synthetic: f"{course_id}::{final-url-segment}"
    type: OcwResourceType
    title: str
    url: str  # absolute
    lecture_id: Optional[str] = None  # assigned by the matcher


@dataclass
class OcwLecture:
    id: str  # f"{course_id}/{lecture_slug}"
    slug: str
    title: str
    mp4_url: Optional[str] = None
    duration_seconds: Optional[int] = None
    resources: list[OcwResource] = field(default_factory=list)


@dataclass
class OcwSection:
    title: str
    order: int
    lectures: list[OcwLecture] = field(default_factory=list)


@dataclass
class OcwCourse:
    id: str  # f"ocw:{slug}"
    slug: str
    title: str
    course_number: str
    description: str
    sections: list[OcwSection] = field(default_factory=list)
    orphan_resources: list[OcwResource] = field(default_factory=list)


# -----------------------------------------------------------------------------
# Parsers (module-level, accept HTML strings — testable without HTTP)
# -----------------------------------------------------------------------------


def parse_course_home(html: str, slug: str) -> dict:
    """
    Parse the course home page.

    Returns a dict with the shape:
        {
          "title": str,
          "course_number": str,
          "term": Optional[str],
          "description": str,
          "video_gallery_path": Optional[str],  # absolute path on ocw.mit.edu
          "lecture_notes_path": Optional[str],
        }

    Does NOT return the lecture list — that requires fetching video_gallery_path.
    """
    soup = BeautifulSoup(html, "html.parser")

    title = _first_text(soup.select("body.course-home-page h1")) or _first_text(soup.select("h1"))
    if title and "MIT OpenCourseWare" in title:
        title = title.split("|")[0].strip()

    course_number, term = _parse_course_header(soup, slug)
    description = _meta_content(soup, "description") or ""

    video_gallery_path: Optional[str] = None
    lecture_notes_path: Optional[str] = None
    for a in soup.find_all("a", href=True):
        href: str = a["href"]
        text = a.get_text(strip=True).lower()
        if f"/courses/{slug}/video_galleries/" in href and video_gallery_path is None:
            video_gallery_path = href
        elif (
            f"/courses/{slug}/pages/lecture-notes" in href
            and text in ("lecture notes", "lecture-notes")
            and lecture_notes_path is None
        ):
            lecture_notes_path = href

    return {
        "title": (title or slug).strip(),
        "course_number": course_number,
        "term": term,
        "description": description.strip(),
        "video_gallery_path": video_gallery_path,
        "lecture_notes_path": lecture_notes_path,
    }


def parse_video_gallery(html: str, slug: str) -> list[dict]:
    """
    Parse a video gallery page and return an ordered list of lectures.

    Returns:
        [{"slug": "<lecture-slug>", "title": "Lecture N: Title"}]

    OCW video galleries observed so far are flat (no unit/week grouping). This
    parser therefore returns a flat list; the caller places them all under one
    synthetic "Video Lectures" section. If a future course groups lectures by
    <h2>/<h3> between link groups, extend here.
    """
    soup = BeautifulSoup(html, "html.parser")
    prefix = f"/courses/{slug}/resources/"
    seen: set[str] = set()
    lectures: list[dict] = []
    for a in soup.find_all("a", href=True):
        href = a["href"]
        if not href.startswith(prefix):
            continue
        lecture_slug = href[len(prefix):].strip("/").split("/")[0]
        if not lecture_slug or not lecture_slug.lower().startswith("lecture"):
            continue
        if lecture_slug in seen:
            continue
        seen.add(lecture_slug)
        lectures.append({
            "slug": lecture_slug,
            "title": a.get_text(strip=True),
        })
    return lectures


def parse_lecture_page(html: str) -> dict:
    """
    Parse a single lecture page.

    Returns:
        {
          "title": str,
          "mp4_url": Optional[str],
          "duration_seconds": Optional[int],  # always None today; OCW pages don't surface duration
        }

    MP4 rule: pick the FIRST <a> whose visible text matches "Download video"
    (case-insensitive, whitespace-collapsed) and whose href contains archive.org
    or ends in .mp4. YouTube iframes are ignored.
    """
    soup = BeautifulSoup(html, "html.parser")

    # On a lecture page, <h1> is the course title and <h2> is the lecture
    # title. The <title> tag always has the lecture title in the first
    # pipe-separated segment, so we prefer it.
    title = ""
    raw_title = _first_text(soup.select("title"))
    if raw_title:
        title = raw_title.split("|")[0].strip()
    if not title:
        for h2 in soup.select("h2"):
            t = h2.get_text(strip=True)
            if t and t.lower().startswith(("lecture", "lec ", "recitation", "session")):
                title = t
                break

    mp4_url: Optional[str] = None
    for a in soup.find_all("a", href=True):
        text = " ".join(a.get_text(strip=True).lower().split())
        if "download video" not in text:
            continue
        href = a["href"]
        if "archive.org" in href or href.lower().endswith(".mp4"):
            mp4_url = href
            break

    return {
        "title": title.strip(),
        "mp4_url": mp4_url,
        "duration_seconds": None,
    }


def parse_lecture_notes_page(html: str, slug: str, base_url: str = OCW_BASE) -> list[dict]:
    """
    Parse the /pages/lecture-notes/ (or equivalent) page.

    Returns:
        [{"title": str, "url": str, "type": "lecture-notes"}]

    Detection rule: <a> whose visible text contains "(PDF" (marker OCW uses to
    denote a downloadable file) and whose href points under this course's
    /resources/ path. Resources are left un-matched here; the matcher assigns
    lecture_id later.
    """
    soup = BeautifulSoup(html, "html.parser")
    resource_prefix = f"/courses/{slug}/resources/"
    out: list[dict] = []
    seen: set[str] = set()
    for a in soup.find_all("a", href=True):
        href = a["href"]
        text = a.get_text(strip=True)
        if not text:
            continue
        # OCW marks downloadable files with "(PDF" in the link text.
        if "(PDF" not in text.upper() and not href.lower().endswith(".pdf"):
            continue
        # Must be a resource under this course (skip cross-course links).
        if not href.startswith(resource_prefix) and not href.lower().endswith(".pdf"):
            continue
        if href in seen:
            continue
        seen.add(href)
        absolute = href if href.startswith("http") else urljoin(base_url, href)
        out.append({
            "title": _clean_resource_title(text),
            "url": absolute,
            "type": OcwResourceType.LECTURE_NOTES.value,
        })
    return out


# -----------------------------------------------------------------------------
# Resource → lecture matching
# -----------------------------------------------------------------------------


_RE_LECTURE_NUM = re.compile(r"(?i)\blec(?:ture)?\s*(\d+)")
_RE_TRAILING_PDF_NUM = re.compile(r"(?i)\b(\d+)\.pdf$")
_RE_LEADING_FILENUM = re.compile(r"^(\d+)[_\-.]")
_RE_LSLUG_NUM = re.compile(r"(?i)_l(\d+)\b")


def extract_lecture_number(text: str) -> Optional[int]:
    """
    Pull a lecture number out of a title or filename-ish string.

    Rules (first match wins):
      1. "Lecture 14" / "Lec 14" / "Lecture14"
      2. Trailing ".pdf" with a number: "L14.pdf" → not matched here; see rule 3
      3. Leading number then separator: "01_handout.pdf" → 1
      4. "_l14" in a URL slug: "mit9_13s19_l14" → 14
    """
    m = _RE_LECTURE_NUM.search(text)
    if m:
        return int(m.group(1))
    m = _RE_LSLUG_NUM.search(text)
    if m:
        return int(m.group(1))
    m = _RE_TRAILING_PDF_NUM.search(text)
    if m:
        return int(m.group(1))
    m = _RE_LEADING_FILENUM.search(text)
    if m:
        return int(m.group(1))
    return None


def _normalize(s: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9 ]+", " ", s.lower())).strip()


def match_resources_to_lectures(
    lectures: list[OcwLecture], resources: list[OcwResource]
) -> tuple[list[OcwResource], list[OcwResource]]:
    """
    Match each resource to at most one lecture by name.

    Algorithm:
      1. If the resource title or URL yields a lecture number, and a lecture
         with the same number exists → assign there.
      2. Else, if a lecture title is a (normalized) prefix of the resource
         title (or vice-versa) → assign to the first such lecture.
      3. Else → orphan.

    "Recitation N" is deliberately NOT treated as "Lecture N": `extract_lecture_number`
    only matches the literal "lecture"/"lec" prefix.

    Returns `(matched_resources, orphan_resources)`. The input `resources` list
    is mutated: each matched resource has its `lecture_id` field set.
    """
    matched: list[OcwResource] = []
    orphans: list[OcwResource] = []
    by_num: dict[int, OcwLecture] = {}
    for lec in lectures:
        n = extract_lecture_number(lec.title) or extract_lecture_number(lec.slug)
        if n is not None and n not in by_num:
            by_num[n] = lec

    for r in resources:
        r_num = extract_lecture_number(r.title) or extract_lecture_number(r.url)
        if r_num is not None and r_num in by_num:
            lec = by_num[r_num]
            r.lecture_id = lec.id
            lec.resources.append(r)
            matched.append(r)
            continue
        # Fallback: normalized-prefix match
        r_norm = _normalize(r.title)
        assigned = False
        for lec in lectures:
            l_norm = _normalize(lec.title)
            if not l_norm or not r_norm:
                continue
            if r_norm.startswith(l_norm) or l_norm.startswith(r_norm):
                r.lecture_id = lec.id
                lec.resources.append(r)
                matched.append(r)
                assigned = True
                break
        if not assigned:
            orphans.append(r)
    return matched, orphans


# -----------------------------------------------------------------------------
# HTTP client
# -----------------------------------------------------------------------------


class OcwClient:
    """HTTP client for ocw.mit.edu. No auth. All GETs."""

    def __init__(
        self,
        base_url: str = OCW_BASE,
        session: Optional[requests.Session] = None,
        timeout: int = 20,
    ):
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.session = session or requests.Session()
        self.session.headers.setdefault("User-Agent", _UA)

    def _get(self, path: str) -> str:
        url = path if path.startswith("http") else urljoin(self.base_url + "/", path.lstrip("/"))
        r = self.session.get(url, timeout=self.timeout)
        r.raise_for_status()
        return r.text

    def fetch_course_home(self, slug: str) -> str:
        return self._get(f"/courses/{slug}/")

    def fetch_video_gallery(self, path: str) -> str:
        return self._get(path)

    def fetch_lecture_page(self, path: str) -> str:
        return self._get(path)

    def fetch_lecture_notes_page(self, path: str) -> str:
        return self._get(path)

    def get_course(self, slug: str) -> OcwCourse:
        """
        Orchestrate: fetch home → fetch gallery → fetch each lecture (for mp4)
        → fetch lecture-notes page → match resources.

        Note: this makes one HTTP call per lecture. For a 35-lecture course
        that's 35 + 3 requests. Callers wanting to batch should use the
        fixture-based path via `build_course_from_fixtures`.
        """
        course_id = f"ocw:{slug}"
        home_html = self.fetch_course_home(slug)
        home = parse_course_home(home_html, slug)

        lectures: list[OcwLecture] = []
        if home["video_gallery_path"]:
            gallery_html = self.fetch_video_gallery(home["video_gallery_path"])
            for lec_ref in parse_video_gallery(gallery_html, slug):
                lecture_path = f"/courses/{slug}/resources/{lec_ref['slug']}/"
                try:
                    lec_html = self.fetch_lecture_page(lecture_path)
                    lec_info = parse_lecture_page(lec_html)
                except requests.HTTPError:
                    lec_info = {"title": lec_ref["title"], "mp4_url": None, "duration_seconds": None}
                lectures.append(OcwLecture(
                    id=f"{course_id}/{lec_ref['slug']}",
                    slug=lec_ref["slug"],
                    title=lec_ref["title"] or lec_info["title"],
                    mp4_url=lec_info.get("mp4_url"),
                    duration_seconds=lec_info.get("duration_seconds"),
                ))

        resources: list[OcwResource] = []
        if home["lecture_notes_path"]:
            notes_html = self.fetch_lecture_notes_page(home["lecture_notes_path"])
            for r in parse_lecture_notes_page(notes_html, slug, self.base_url):
                rid = _synth_resource_id(course_id, r["url"])
                resources.append(OcwResource(
                    id=rid,
                    type=OcwResourceType(r["type"]),
                    title=r["title"],
                    url=r["url"],
                ))

        _matched, orphans = match_resources_to_lectures(lectures, resources)

        section = OcwSection(title="Video Lectures", order=0, lectures=lectures)
        return OcwCourse(
            id=course_id,
            slug=slug,
            title=home["title"],
            course_number=home["course_number"],
            description=home["description"],
            sections=[section] if lectures else [],
            orphan_resources=orphans,
        )


# -----------------------------------------------------------------------------
# Fixture loader (offline, deterministic — used by CLI --fixture-dir + tests)
# -----------------------------------------------------------------------------


def build_course_from_fixtures(slug: str, fixture_dir: str | Path) -> OcwCourse:
    """
    Build an OcwCourse from a fixture directory containing:
      - course_home.html                (required)
      - video_gallery.html              (optional; if absent, no lectures)
      - lecture_{slug}.html             (optional; per-lecture MP4 lookup)
      - lecture_notes.html              (optional; resources)

    Mirrors `OcwClient.get_course` but reads from disk instead of HTTP.
    """
    d = Path(fixture_dir)
    course_id = f"ocw:{slug}"
    home = parse_course_home((d / "course_home.html").read_text(), slug)

    lectures: list[OcwLecture] = []
    gallery = d / "video_gallery.html"
    if gallery.exists():
        for lec_ref in parse_video_gallery(gallery.read_text(), slug):
            lec_file = d / f"lecture_{lec_ref['slug']}.html"
            if not lec_file.exists():
                # Common shorthand for the first lecture fixture
                lec_file = d / "lecture_1.html" if lec_ref["slug"].startswith("lecture-1-") else lec_file
            info = {"title": lec_ref["title"], "mp4_url": None, "duration_seconds": None}
            if lec_file.exists():
                info = parse_lecture_page(lec_file.read_text())
            lectures.append(OcwLecture(
                id=f"{course_id}/{lec_ref['slug']}",
                slug=lec_ref["slug"],
                title=lec_ref["title"] or info["title"],
                mp4_url=info.get("mp4_url"),
                duration_seconds=info.get("duration_seconds"),
            ))

    resources: list[OcwResource] = []
    notes = d / "lecture_notes.html"
    if notes.exists():
        for r in parse_lecture_notes_page(notes.read_text(), slug):
            rid = _synth_resource_id(course_id, r["url"])
            resources.append(OcwResource(
                id=rid,
                type=OcwResourceType(r["type"]),
                title=r["title"],
                url=r["url"],
            ))

    _matched, orphans = match_resources_to_lectures(lectures, resources)
    section = OcwSection(title="Video Lectures", order=0, lectures=lectures)
    return OcwCourse(
        id=course_id,
        slug=slug,
        title=home["title"],
        course_number=home["course_number"],
        description=home["description"],
        sections=[section] if lectures else [],
        orphan_resources=orphans,
    )


def course_to_dict(course: OcwCourse) -> dict:
    """Serialize an OcwCourse to a JSON-safe dict."""
    return asdict(course)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------


def _first_text(nodes) -> Optional[str]:
    for n in nodes:
        t = n.get_text(strip=True) if hasattr(n, "get_text") else str(n).strip()
        if t:
            return t
    return None


def _meta_content(soup: BeautifulSoup, name: str) -> Optional[str]:
    el = soup.find("meta", attrs={"name": name})
    if el and el.get("content"):
        return el["content"]
    el = soup.find("meta", attrs={"property": f"og:{name}"})
    if el and el.get("content"):
        return el["content"]
    return None


_RE_COURSE_HEADER = re.compile(r"([0-9]+(?:\.[0-9]+)*[a-zA-Z]*)\s*\|\s*([^|]+?)\s*(?:\||$)")


def _parse_course_header(soup: BeautifulSoup, slug: str) -> tuple[str, Optional[str]]:
    """
    Extract course number + term from a header span like
        "9.13 | Spring 2019 | Undergraduate"
    Falls back to deriving the course number from the URL slug.
    """
    for span in soup.find_all(["span", "div"]):
        text = span.get_text(" ", strip=True)
        if "|" not in text or len(text) > 120:
            continue
        m = _RE_COURSE_HEADER.match(text)
        if m:
            return m.group(1), m.group(2).strip()
    return _course_number_from_slug(slug), None


def _course_number_from_slug(slug: str) -> str:
    """
    Derive a canonical course number from an OCW slug.

    Rules:
      - Take leading numeric-or-alphanumeric segments until we hit a pure-alpha
        segment longer than 2 chars (i.e. the start of the title).
      - Join with "." instead of "-".

    Examples:
      9-13-the-human-brain-spring-2019            -> 9.13
      18-06-linear-algebra-spring-2010            -> 18.06
      6-006-introduction-to-algorithms-fall-2011  -> 6.006
      8-01sc-classical-mechanics-fall-2016        -> 8.01sc
    """
    parts: list[str] = []
    for seg in slug.split("-"):
        if seg.isalpha() and len(seg) > 2:
            break
        parts.append(seg)
        if len(parts) >= 3:
            break
    return ".".join(parts) if parts else slug


_RE_CLEAN_TITLE = re.compile(r"\s*\(PDF[^)]*\)\s*$", re.IGNORECASE)


def _clean_resource_title(text: str) -> str:
    """Strip the trailing '(PDF)' / '(PDF - 1.6MB)' suffix OCW appends."""
    return _RE_CLEAN_TITLE.sub("", text).strip()


def _synth_resource_id(course_id: str, url: str) -> str:
    """Synthesize a stable resource id from course + url final segment."""
    last = url.rstrip("/").rsplit("/", 1)[-1]
    return f"{course_id}::{last}"


__all__ = [
    "OCW_BASE",
    "OcwClient",
    "OcwCourse",
    "OcwSection",
    "OcwLecture",
    "OcwResource",
    "OcwResourceType",
    "build_course_from_fixtures",
    "course_to_dict",
    "extract_lecture_number",
    "match_resources_to_lectures",
    "parse_course_home",
    "parse_lecture_notes_page",
    "parse_lecture_page",
    "parse_video_gallery",
]
