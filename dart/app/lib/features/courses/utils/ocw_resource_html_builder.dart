// Builds synthesized "xblock-like" HTML for OCW resource tiles so they flow
// through the existing `sanitizeXBlockHtml` allowlist (see
// `specs/sane-html-parsing.md`). The sanitizer keeps content inside
// `[data-block-type="html"]` and drops everything else, so we wrap our
// output in exactly that marker.
import 'package:omnilect/features/courses/models/ocw_course.dart';

const Map<OcwResourceType, String> _sectionHeadings = {
  OcwResourceType.lectureNotes: 'Lecture notes',
  OcwResourceType.lectureSlides: 'Lecture slides',
};

// Fixed section order: lecture-notes first, slides second. Matches the
// ordering used in `specs/opencourseware-support.md` §"Synthesized resource
// xblock HTML".
const List<OcwResourceType> _sectionOrder = [
  OcwResourceType.lectureNotes,
  OcwResourceType.lectureSlides,
];

/// Generate the HTML body shown in the collapsible content tile under an OCW
/// lecture's video. Groups resources by type in a fixed order; omits empty
/// sections. Returns the empty string when [resources] is empty so the tile
/// falls back to the existing "No additional content for this section."
/// empty-state UI.
String buildOcwResourceHtml(List<OcwResource> resources) {
  if (resources.isEmpty) return '';

  final byType = <OcwResourceType, List<OcwResource>>{};
  for (final r in resources) {
    byType.putIfAbsent(r.type, () => []).add(r);
  }

  final buf = StringBuffer('<div data-block-type="html">');
  for (final type in _sectionOrder) {
    final group = byType[type];
    if (group == null || group.isEmpty) continue;
    buf
      ..write('<h3>')
      ..write(_escape(_sectionHeadings[type]!))
      ..write('</h3><ul>');
    for (final r in group) {
      buf
        ..write('<li><a href="')
        ..write(_escapeAttr(r.url))
        ..write('">')
        ..write(_escape(r.title))
        ..write('</a></li>');
    }
    buf.write('</ul>');
  }
  buf.write('</div>');
  return buf.toString();
}

String _escape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

String _escapeAttr(String s) => _escape(s).replaceAll("'", '&#39;');
