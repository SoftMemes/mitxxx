import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_html_builder.dart';
import 'package:omnilect/features/courses/utils/xblock_parser.dart';

OcwResource _r(OcwResourceType type, String title, String url) =>
    OcwResource(id: '$url-$title', type: type, title: title, url: url);

void main() {
  test('empty list returns empty string', () {
    expect(buildOcwResourceHtml(const []), '');
  });

  test('single notes entry renders one section with one link', () {
    final html = buildOcwResourceHtml([
      _r(OcwResourceType.lectureNotes, 'Lecture 1: Intro',
          'https://ocw.mit.edu/courses/x/resources/n1/'),
    ]);
    expect(html, contains('data-block-type="html"'));
    expect(html, contains('<h3>Lecture notes</h3>'));
    expect(html, contains('<a href="https://ocw.mit.edu/courses/x/resources/n1/">Lecture 1: Intro</a>'));
    expect(html, isNot(contains('Lecture slides')));
  });

  test('two types render in fixed order: notes, then slides', () {
    final html = buildOcwResourceHtml([
      _r(OcwResourceType.lectureSlides, 'L1 slides', 'https://x/s1'),
      _r(OcwResourceType.lectureNotes, 'L1 notes', 'https://x/n1'),
    ]);
    final notesIdx = html.indexOf('Lecture notes');
    final slidesIdx = html.indexOf('Lecture slides');
    expect(notesIdx, greaterThan(-1));
    expect(slidesIdx, greaterThan(-1));
    expect(notesIdx, lessThan(slidesIdx));
  });

  test('HTML-escapes title and URL', () {
    final html = buildOcwResourceHtml([
      _r(OcwResourceType.lectureNotes, 'Q&A: "Intro" <core>',
          'https://x/path?a=1&b=2'),
    ]);
    expect(html, contains('Q&amp;A: &quot;Intro&quot; &lt;core&gt;'));
    expect(html, contains('https://x/path?a=1&amp;b=2'));
  });

  test('flows through sanitizeXBlockHtml unchanged', () {
    // The point of wrapping in <div data-block-type="html"> is that the
    // existing sanitizer's allowlist keeps it. We assert the sanitizer output
    // still contains the links and headings — not byte-equivalent, since the
    // sanitizer rewraps in its own document frame.
    final html = buildOcwResourceHtml([
      _r(OcwResourceType.lectureNotes, 'Lecture 1: Intro', 'https://ocw.mit.edu/n1'),
      _r(OcwResourceType.lectureSlides, 'Lecture 1: Slides', 'https://ocw.mit.edu/s1'),
    ]);
    final sanitized = sanitizeXBlockHtml(html);
    expect(sanitized, contains('Lecture notes'));
    expect(sanitized, contains('Lecture slides'));
    expect(sanitized, contains('https://ocw.mit.edu/n1'));
    expect(sanitized, contains('https://ocw.mit.edu/s1'));
  });
}
