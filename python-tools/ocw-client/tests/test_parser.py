"""Fixture-based parser tests. No network calls."""
from pathlib import Path

import pytest

from client import (
    build_course_from_fixtures,
    parse_course_home,
    parse_lecture_notes_page,
    parse_lecture_page,
    parse_video_gallery,
)

FIXTURES = Path(__file__).parent.parent / "fixtures"
BRAIN = "9-13-the-human-brain-spring-2019"
LINALG = "18-06-linear-algebra-spring-2010"


def _read(slug: str, name: str) -> str:
    return (FIXTURES / slug / name).read_text()


# -----------------------------------------------------------------------------
# parse_course_home
# -----------------------------------------------------------------------------


def test_course_home_brain():
    home = parse_course_home(_read(BRAIN, "course_home.html"), BRAIN)
    assert home["title"] == "The Human Brain"
    assert home["course_number"] == "9.13"
    assert home["term"] == "Spring 2019"
    assert home["description"].startswith("This course surveys the core perceptual")
    assert home["video_gallery_path"] == f"/courses/{BRAIN}/video_galleries/lecture-videos/"
    assert home["lecture_notes_path"] == f"/courses/{BRAIN}/pages/lecture-notes/"


def test_course_home_linalg():
    home = parse_course_home(_read(LINALG, "course_home.html"), LINALG)
    assert home["title"] == "Linear Algebra"
    assert home["course_number"] == "18.06"
    assert home["description"].startswith("This is a basic subject on matrix theory")
    assert home["video_gallery_path"] == f"/courses/{LINALG}/video_galleries/video-lectures/"
    # 18.06 has no lecture-notes page
    assert home["lecture_notes_path"] is None


# -----------------------------------------------------------------------------
# parse_video_gallery
# -----------------------------------------------------------------------------


def test_video_gallery_brain_flat_17_lectures():
    lectures = parse_video_gallery(_read(BRAIN, "video_gallery.html"), BRAIN)
    assert len(lectures) == 17
    assert lectures[0]["slug"] == "lecture-1-introduction"
    assert lectures[0]["title"].startswith("Lecture 1:")
    assert all(l["slug"].startswith("lecture-") for l in lectures)


def test_video_gallery_linalg_35_lectures():
    lectures = parse_video_gallery(_read(LINALG, "video_gallery.html"), LINALG)
    assert len(lectures) == 35
    # Final-review lecture comes last
    assert lectures[-1]["slug"].startswith("lecture-34-")


# -----------------------------------------------------------------------------
# parse_lecture_page
# -----------------------------------------------------------------------------


def test_lecture_page_brain_extracts_archive_mp4():
    info = parse_lecture_page(_read(BRAIN, "lecture_1.html"))
    assert info["title"].startswith("Lecture 1:")
    assert info["mp4_url"] == "https://archive.org/download/MIT9.13S19/MIT9_13S19_lec01_300k.mp4"
    assert info["duration_seconds"] is None


def test_lecture_page_linalg_extracts_archive_mp4():
    info = parse_lecture_page(_read(LINALG, "lecture_1.html"))
    assert info["title"].startswith("Lecture 1:")
    assert info["mp4_url"] == "http://www.archive.org/download/MIT18.06S05_MP4/01.mp4"


def test_lecture_page_ignores_youtube_iframe():
    # The brain fixture has a YouTube iframe — ensure we don't pick it up.
    info = parse_lecture_page(_read(BRAIN, "lecture_1.html"))
    assert "youtube" not in (info["mp4_url"] or "")


# -----------------------------------------------------------------------------
# parse_lecture_notes_page
# -----------------------------------------------------------------------------


def test_lecture_notes_brain_17_pdfs():
    resources = parse_lecture_notes_page(_read(BRAIN, "lecture_notes.html"), BRAIN)
    assert len(resources) == 17
    sample = resources[0]
    assert sample["type"] == "lecture-notes"
    assert sample["title"] == "Lecture 1: Introduction"
    assert sample["url"].startswith("https://ocw.mit.edu/courses/")
    # Title strips the "(PDF)" / "(PDF - 1.6MB)" suffix
    assert "(PDF" not in sample["title"]


# -----------------------------------------------------------------------------
# End-to-end: build_course_from_fixtures
# -----------------------------------------------------------------------------


def test_build_course_brain_happy_path():
    c = build_course_from_fixtures(BRAIN, FIXTURES / BRAIN)
    assert c.id == f"ocw:{BRAIN}"
    assert c.title == "The Human Brain"
    assert c.course_number == "9.13"
    assert len(c.sections) == 1
    assert c.sections[0].title == "Video Lectures"
    assert len(c.sections[0].lectures) == 17
    # All 17 notes got matched to their lecture — zero orphans
    assert c.orphan_resources == []
    lec1 = c.sections[0].lectures[0]
    assert lec1.mp4_url == "https://archive.org/download/MIT9.13S19/MIT9_13S19_lec01_300k.mp4"
    assert len(lec1.resources) == 1
    # Every matched resource points to the correct lecture's _l{NN} slug
    for lec in c.sections[0].lectures:
        n = lec.title.split(":", 1)[0].replace("Lecture", "").strip()
        for r in lec.resources:
            assert f"_l{int(n):02d}" in r.url, f"mismatch: {lec.title} -> {r.url}"


def test_build_course_linalg_no_notes_page():
    c = build_course_from_fixtures(LINALG, FIXTURES / LINALG)
    assert c.course_number == "18.06"
    assert len(c.sections[0].lectures) == 35
    # 18.06 has no lecture-notes page → zero resources everywhere
    assert c.orphan_resources == []
    for lec in c.sections[0].lectures:
        assert lec.resources == []


def test_no_network_during_fixture_tests(monkeypatch):
    """Guard: fixture-based tests must not touch the network."""
    import requests

    def boom(*args, **kwargs):  # pragma: no cover
        raise AssertionError("fixture tests made a real HTTP call")

    monkeypatch.setattr(requests.Session, "get", boom)
    # Re-run the representative test path
    c = build_course_from_fixtures(BRAIN, FIXTURES / BRAIN)
    assert c.title == "The Human Brain"
