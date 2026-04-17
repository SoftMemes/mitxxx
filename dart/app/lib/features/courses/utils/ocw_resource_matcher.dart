// Port of `match_resources_to_lectures` + `extract_lecture_number` from
// `python-tools/ocw-client/client.py`. See the Python file for the rationale
// and test fixtures.
import 'package:omnilect/features/courses/models/ocw_course.dart';

final RegExp _reLectureNum =
    RegExp(r'\blec(?:ture)?\s*(\d+)', caseSensitive: false);
final RegExp _reLSlug = RegExp(r'_l(\d+)\b', caseSensitive: false);
final RegExp _reTrailingPdfNum =
    RegExp(r'\b(\d+)\.pdf$', caseSensitive: false);
final RegExp _reLeadingFilenum = RegExp(r'^(\d+)[_\-.]');

/// Extract a lecture number from a title, filename, or URL path segment.
/// Rules (first match wins) — keep in sync with the Python reference so the
/// fixture-derived expectations pass:
///
///   1. "Lecture 14" / "Lec 14"           via `_reLectureNum`
///   2. URL _l14 slug                     via `_reLSlug`
///   3. Trailing "N.pdf"                  via `_reTrailingPdfNum`
///   4. Leading "N_", "N-", "N."          via `_reLeadingFilenum`
///
/// Deliberately does NOT match "Recitation 14" / "Session 14" — those aren't
/// lectures.
int? extractLectureNumber(String text) {
  final m = _reLectureNum.firstMatch(text);
  if (m != null) return int.parse(m.group(1)!);
  final m2 = _reLSlug.firstMatch(text);
  if (m2 != null) return int.parse(m2.group(1)!);
  final m3 = _reTrailingPdfNum.firstMatch(text);
  if (m3 != null) return int.parse(m3.group(1)!);
  final m4 = _reLeadingFilenum.firstMatch(text);
  if (m4 != null) return int.parse(m4.group(1)!);
  return null;
}

String _normalize(String s) => s
    .toLowerCase()
    .replaceAll(RegExp('[^a-z0-9 ]+'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Result of [matchResourcesToLectures].
class OcwMatchResult {
  const OcwMatchResult({required this.lectures, required this.orphans});

  /// Lectures with matched resources attached to them (new instances — the
  /// input list is NOT mutated).
  final List<OcwLecture> lectures;

  /// Resources that couldn't be matched to any lecture.
  final List<OcwResource> orphans;
}

/// Match every resource to at most one lecture by name.
///
/// Algorithm:
///   1. Lookup by lecture number (both sides). First lecture with that number
///      wins.
///   2. Fallback: normalised-title prefix match in either direction, first hit.
///   3. Else orphan.
OcwMatchResult matchResourcesToLectures(
  List<OcwLecture> lectures,
  List<OcwResource> resources,
) {
  // Build number → first-lecture lookup.
  final byNum = <int, int>{}; // lecture-number -> index in lectures
  for (var i = 0; i < lectures.length; i++) {
    final lec = lectures[i];
    final n = extractLectureNumber(lec.title) ?? extractLectureNumber(lec.slug);
    if (n != null && !byNum.containsKey(n)) byNum[n] = i;
  }

  // Build per-index resource buckets + immutable output.
  final buckets = List<List<OcwResource>>.generate(
    lectures.length,
    (_) => <OcwResource>[],
  );
  final orphans = <OcwResource>[];

  for (final r in resources) {
    final rNum = extractLectureNumber(r.title) ?? extractLectureNumber(r.url);
    if (rNum != null && byNum.containsKey(rNum)) {
      final idx = byNum[rNum]!;
      buckets[idx].add(r.copyWith(lectureId: lectures[idx].id));
      continue;
    }
    final rNorm = _normalize(r.title);
    var assigned = false;
    for (var i = 0; i < lectures.length; i++) {
      final lNorm = _normalize(lectures[i].title);
      if (lNorm.isEmpty || rNorm.isEmpty) continue;
      if (rNorm.startsWith(lNorm) || lNorm.startsWith(rNorm)) {
        buckets[i].add(r.copyWith(lectureId: lectures[i].id));
        assigned = true;
        break;
      }
    }
    if (!assigned) orphans.add(r);
  }

  final matchedLectures = <OcwLecture>[
    for (var i = 0; i < lectures.length; i++)
      lectures[i].copyWith(
        resources: [...lectures[i].resources, ...buckets[i]],
      ),
  ];

  return OcwMatchResult(lectures: matchedLectures, orphans: orphans);
}
