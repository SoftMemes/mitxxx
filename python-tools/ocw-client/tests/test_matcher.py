"""Unit tests for extract_lecture_number and match_resources_to_lectures."""
from client import (
    OcwLecture,
    OcwResource,
    OcwResourceType,
    extract_lecture_number,
    match_resources_to_lectures,
)


# -----------------------------------------------------------------------------
# extract_lecture_number
# -----------------------------------------------------------------------------


def test_extract_from_lecture_phrase():
    assert extract_lecture_number("Lecture 14: The Visual Cortex") == 14
    assert extract_lecture_number("Lecture14") == 14
    assert extract_lecture_number("Lec 7") == 7
    assert extract_lecture_number("lecture 3") == 3


def test_extract_from_l_slug_in_url():
    assert extract_lecture_number("mit9_13s19_l01") == 1
    assert extract_lecture_number("mit9_13s19_l14") == 14
    # Two-digit number must come out as two digits, not "l1"
    assert extract_lecture_number("/resources/mit9_13s19_l11/") == 11


def test_extract_from_trailing_pdf():
    assert extract_lecture_number("notes-3.pdf") == 3
    # Should still find it embedded in a path
    assert extract_lecture_number("handouts/lec-5.pdf") == 5


def test_extract_from_leading_filenum():
    assert extract_lecture_number("01_handout.pdf") == 1
    assert extract_lecture_number("12_slides.pdf") == 12


def test_extract_recitation_is_not_a_lecture():
    # "Recitation 14" must not be treated as "Lecture 14"
    assert extract_lecture_number("Recitation 14: review") is None


def test_extract_none_when_no_number():
    assert extract_lecture_number("Course Overview") is None
    assert extract_lecture_number("Introduction") is None


# -----------------------------------------------------------------------------
# match_resources_to_lectures
# -----------------------------------------------------------------------------


def _lec(course_id: str, n: int, title: str, slug: str | None = None) -> OcwLecture:
    return OcwLecture(
        id=f"{course_id}/lecture-{n}",
        slug=slug or f"lecture-{n}-x",
        title=title,
    )


def _res(course_id: str, key: str, title: str, url: str | None = None) -> OcwResource:
    return OcwResource(
        id=f"{course_id}::{key}",
        type=OcwResourceType.LECTURE_NOTES,
        title=title,
        url=url or f"https://ocw.mit.edu/r/{key}",
    )


def test_match_by_lecture_number_one_to_one():
    cid = "ocw:c"
    lectures = [_lec(cid, 1, "Lecture 1: Intro"), _lec(cid, 14, "Lecture 14: Visual")]
    resources = [
        _res(cid, "n1", "Lecture 1: Intro (PDF)"),
        _res(cid, "n14", "Lecture 14: Visual (PDF - 1.2MB)"),
    ]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert len(matched) == 2
    assert orphans == []
    assert resources[0].lecture_id == lectures[0].id
    assert resources[1].lecture_id == lectures[1].id
    assert len(lectures[0].resources) == 1
    assert len(lectures[1].resources) == 1


def test_match_uses_url_l_slug_when_title_lacks_number():
    cid = "ocw:c"
    lectures = [_lec(cid, 11, "Lecture 11: Development II")]
    # Title has no number, but URL does via _l11
    resources = [_res(cid, "mit9_13s19_l11", "(Fallback) Notes", "https://x/mit9_13s19_l11/")]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert len(matched) == 1
    assert orphans == []


def test_off_by_one_prefix_does_not_collide():
    """Lecture 1 notes must not match Lecture 10's number and vice-versa."""
    cid = "ocw:c"
    lectures = [_lec(cid, 1, "Lecture 1: Intro"), _lec(cid, 10, "Lecture 10: Later")]
    resources = [
        _res(cid, "n10", "Lecture 10: Later (PDF)"),
        _res(cid, "n1", "Lecture 1: Intro (PDF)"),
    ]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert orphans == []
    assert resources[0].lecture_id == lectures[1].id  # "Lecture 10" → lec 10
    assert resources[1].lecture_id == lectures[0].id  # "Lecture 1" → lec 1


def test_recitation_does_not_match_lecture_with_same_number():
    """A resource titled 'Recitation 14 notes' must NOT match 'Lecture 14'."""
    cid = "ocw:c"
    lectures = [_lec(cid, 14, "Lecture 14: Visual")]
    resources = [_res(cid, "r14", "Recitation 14 review")]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert matched == []
    assert len(orphans) == 1


def test_orphan_when_no_matching_lecture():
    cid = "ocw:c"
    lectures = [_lec(cid, 1, "Lecture 1: Intro")]
    resources = [
        _res(cid, "syllabus", "Course Syllabus (PDF)"),
        _res(cid, "bib", "Full bibliography (PDF)"),
    ]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert matched == []
    assert len(orphans) == 2
    # lectures got no resources attached
    assert lectures[0].resources == []


def test_prefix_fallback_when_no_numbers():
    """When neither side has a lecture number, normalized-prefix match kicks in."""
    cid = "ocw:c"
    lectures = [_lec(cid, 1, "Introduction to Neuroscience")]
    resources = [_res(cid, "intro", "Introduction to Neuroscience — slides")]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert len(matched) == 1
    assert orphans == []


def test_deterministic_tie_breaking_first_lecture_wins():
    cid = "ocw:c"
    lectures = [
        _lec(cid, 1, "Lecture 1: Intro"),
        _lec(cid, 1, "Lecture 1: Intro (dup)"),  # same number; malformed input
    ]
    resources = [_res(cid, "n1", "Lecture 1: Intro (PDF)")]
    matched, orphans = match_resources_to_lectures(lectures, resources)
    assert len(matched) == 1
    assert resources[0].lecture_id == lectures[0].id
    assert lectures[1].resources == []
