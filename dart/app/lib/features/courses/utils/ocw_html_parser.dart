// HTML parser for MIT OpenCourseWare pages. Direct port of the Python
// reference at `python-tools/ocw-client/client.py` — see that file's
// `CLAUDE.md` for URL patterns, extraction rules, and known quirks.
//
// All functions are pure: they accept HTML strings and return plain data. The
// tests live in `test/features/courses/utils/ocw_html_parser_test.dart` and
// exercise them against committed fixture HTML under `test/fixtures/ocw/`.
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:omnilect/features/courses/models/ocw_course.dart';

const String ocwBase = 'https://ocw.mit.edu';

/// Structured result of [parseCourseHome].
class OcwCourseHomeInfo {
  const OcwCourseHomeInfo({
    required this.title,
    required this.courseNumber,
    required this.description,
    this.term,
    this.videoGalleryPath,
    this.lectureNotesPath,
  });

  final String title;
  final String courseNumber;
  final String? term;
  final String description;
  final String? videoGalleryPath;
  final String? lectureNotesPath;
}

/// A link to an individual lecture as extracted from a video-gallery page.
class OcwLectureRef {
  const OcwLectureRef({required this.slug, required this.title});

  final String slug;
  final String title;
}

/// Structured result of [parseLecturePage].
class OcwLectureInfo {
  const OcwLectureInfo({
    required this.title,
    this.mp4Url,
    this.durationSeconds,
  });

  final String title;
  final String? mp4Url;
  final int? durationSeconds;
}

// -----------------------------------------------------------------------------
// parse_course_home
// -----------------------------------------------------------------------------

OcwCourseHomeInfo parseCourseHome(String html, String slug) {
  final doc = html_parser.parse(html);

  var title = _firstText(doc.querySelectorAll('body.course-home-page h1'));
  title ??= _firstText(doc.querySelectorAll('h1'));
  if (title != null && title.contains('MIT OpenCourseWare')) {
    title = title.split('|').first.trim();
  }

  final header = _parseCourseHeader(doc, slug);
  final description = _metaContent(doc, 'description') ?? '';

  String? videoGalleryPath;
  String? lectureNotesPath;
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    final text = a.text.trim().toLowerCase();
    if (href.contains('/courses/$slug/video_galleries/') &&
        videoGalleryPath == null) {
      videoGalleryPath = href;
    } else if (href.contains('/courses/$slug/pages/lecture-notes') &&
        (text == 'lecture notes' || text == 'lecture-notes') &&
        lectureNotesPath == null) {
      lectureNotesPath = href;
    }
  }

  return OcwCourseHomeInfo(
    title: (title ?? slug).trim(),
    courseNumber: header.courseNumber,
    term: header.term,
    description: description.trim(),
    videoGalleryPath: videoGalleryPath,
    lectureNotesPath: lectureNotesPath,
  );
}

// -----------------------------------------------------------------------------
// parse_video_gallery
// -----------------------------------------------------------------------------

List<OcwLectureRef> parseVideoGallery(String html, String slug) {
  final doc = html_parser.parse(html);
  final prefix = '/courses/$slug/resources/';
  final seen = <String>{};
  final out = <OcwLectureRef>[];
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    if (!href.startsWith(prefix)) continue;
    final lectureSlug =
        href.substring(prefix.length).split('/').firstWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            );
    if (lectureSlug.isEmpty ||
        !lectureSlug.toLowerCase().startsWith('lecture')) {
      continue;
    }
    if (seen.contains(lectureSlug)) continue;
    seen.add(lectureSlug);
    out.add(OcwLectureRef(slug: lectureSlug, title: a.text.trim()));
  }
  return out;
}

// -----------------------------------------------------------------------------
// parse_lecture_page
// -----------------------------------------------------------------------------

final RegExp _lectureHeadingPrefix =
    RegExp(r'^(lecture|lec\s|recitation|session)', caseSensitive: false);

OcwLectureInfo parseLecturePage(String html) {
  final doc = html_parser.parse(html);

  // On a lecture page, <h1> is the course title and <h2> is the lecture title.
  // The <title> tag always has the lecture title in the first pipe-separated
  // segment, so we prefer it — matches the Python reference.
  var title = '';
  final rawTitle = _firstText(doc.querySelectorAll('title'));
  if (rawTitle != null) {
    title = rawTitle.split('|').first.trim();
  }
  if (title.isEmpty) {
    for (final h2 in doc.querySelectorAll('h2')) {
      final t = h2.text.trim();
      if (t.isNotEmpty && _lectureHeadingPrefix.hasMatch(t)) {
        title = t;
        break;
      }
    }
  }

  String? mp4Url;
  for (final a in doc.querySelectorAll('a[href]')) {
    final rawText = a.text.trim().toLowerCase();
    final normText = rawText.replaceAll(RegExp(r'\s+'), ' ');
    if (!normText.contains('download video')) continue;
    final href = a.attributes['href'] ?? '';
    if (href.contains('archive.org') || href.toLowerCase().endsWith('.mp4')) {
      mp4Url = href;
      break;
    }
  }

  return OcwLectureInfo(title: title.trim(), mp4Url: mp4Url);
}

// -----------------------------------------------------------------------------
// parse_lecture_notes_page
// -----------------------------------------------------------------------------

final RegExp _cleanPdfSuffix =
    RegExp(r'\s*\(PDF[^)]*\)\s*$', caseSensitive: false);

List<OcwResource> parseLectureNotesPage(
  String html, {
  required String slug,
  required String courseId,
  String baseUrl = ocwBase,
}) {
  final doc = html_parser.parse(html);
  final resourcePrefix = '/courses/$slug/resources/';
  final out = <OcwResource>[];
  final seen = <String>{};
  for (final a in doc.querySelectorAll('a[href]')) {
    final href = a.attributes['href'] ?? '';
    final text = a.text.trim();
    if (text.isEmpty) continue;
    // OCW marks downloadable files with "(PDF" in the link text.
    if (!text.toUpperCase().contains('(PDF') &&
        !href.toLowerCase().endsWith('.pdf')) {
      continue;
    }
    if (!href.startsWith(resourcePrefix) &&
        !href.toLowerCase().endsWith('.pdf')) {
      continue;
    }
    if (seen.contains(href)) continue;
    seen.add(href);
    final absolute = href.startsWith('http')
        ? href
        : _urlJoin(baseUrl, href);
    out.add(OcwResource(
      id: _synthResourceId(courseId, absolute),
      type: OcwResourceType.lectureNotes,
      title: _cleanResourceTitle(text),
      url: absolute,
    ));
  }
  return out;
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

String? _firstText(Iterable<dom.Element> nodes) {
  for (final n in nodes) {
    final t = n.text.trim();
    if (t.isNotEmpty) return t;
  }
  return null;
}

String? _metaContent(dom.Document doc, String name) {
  final byName = doc.querySelector('meta[name="$name"]');
  final content = byName?.attributes['content'];
  if (content != null && content.isNotEmpty) return content;
  final byProperty = doc.querySelector('meta[property="og:$name"]');
  final ogContent = byProperty?.attributes['content'];
  if (ogContent != null && ogContent.isNotEmpty) return ogContent;
  return null;
}

class _CourseHeader {
  const _CourseHeader(this.courseNumber, this.term);
  final String courseNumber;
  final String? term;
}

final RegExp _courseHeaderRe =
    RegExp(r'^([0-9]+(?:\.[0-9]+)*[a-zA-Z]*)\s*\|\s*([^|]+?)\s*(?:\||$)');

_CourseHeader _parseCourseHeader(dom.Document doc, String slug) {
  for (final span in doc.querySelectorAll('span, div')) {
    final text = span.text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (!text.contains('|') || text.length > 120) continue;
    final m = _courseHeaderRe.firstMatch(text);
    if (m != null) {
      return _CourseHeader(m.group(1)!, m.group(2)?.trim());
    }
  }
  return _CourseHeader(courseNumberFromSlug(slug), null);
}

/// Derive a canonical course number from an OCW slug. Public for reuse by the
/// fetcher when the on-page header is missing.
///
/// Examples:
///   9-13-the-human-brain-spring-2019   -> 9.13
///   18-06-linear-algebra-spring-2010   -> 18.06
///   8-01sc-classical-mechanics-fall-2016 -> 8.01sc
String courseNumberFromSlug(String slug) {
  final parts = <String>[];
  for (final seg in slug.split('-')) {
    final isPureAlpha = seg.isNotEmpty && seg.codeUnits.every(_isAlpha);
    if (isPureAlpha && seg.length > 2) break;
    parts.add(seg);
    if (parts.length >= 3) break;
  }
  return parts.isEmpty ? slug : parts.join('.');
}

bool _isAlpha(int c) =>
    (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);

String _cleanResourceTitle(String text) =>
    text.replaceFirst(_cleanPdfSuffix, '').trim();

String _synthResourceId(String courseId, String url) {
  final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
  final last = trimmed.split('/').last;
  return '$courseId::$last';
}

String _urlJoin(String base, String path) {
  if (path.startsWith('http')) return path;
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  final p = path.startsWith('/') ? path : '/$path';
  return '$b$p';
}
