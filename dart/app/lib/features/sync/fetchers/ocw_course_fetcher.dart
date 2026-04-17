import 'dart:async';

import 'package:dio/dio.dart';
import 'package:logging/logging.dart';
import 'package:omnilect/features/courses/models/ocw_course.dart';
import 'package:omnilect/features/courses/utils/ocw_html_parser.dart';
import 'package:omnilect/features/courses/utils/ocw_resource_matcher.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'ocw_course_fetcher.g.dart';

final _log = Logger('ocw-fetcher');

/// Maximum number of concurrent lecture-page fetches per course. Polite to the
/// ocw.mit.edu origin while keeping a 35-lecture course under ~10 seconds on a
/// fast connection.
const int _lectureConcurrency = 4;

/// Normalises legacy `http://` archive.org links to `https://`. The 18.06
/// fixture is the known producer; archive.org serves both but the download
/// layer uses the URL as primary key, so consistency matters.
String _normaliseMp4Url(String url) {
  if (url.startsWith('http://www.archive.org/')) {
    return 'https://www.archive.org/${url.substring('http://www.archive.org/'.length)}';
  }
  if (url.startsWith('http://archive.org/')) {
    return 'https://archive.org/${url.substring('http://archive.org/'.length)}';
  }
  return url;
}

/// Fetches an OCW course end-to-end from ocw.mit.edu. The whole thing is one
/// HTTP flow per [fetchCourse] call; there is no caching inside the fetcher —
/// callers persist the result into Drift.
class OcwCourseFetcher {
  OcwCourseFetcher({Dio? dio})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: ocwBase,
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(seconds: 60),
                headers: {
                  'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9',
                },
              ),
            );

  final Dio _dio;

  /// Fetch [slug] — e.g. `9-13-the-human-brain-spring-2019` — and return a
  /// fully matched [OcwCourse]. [courseId] is `"ocw:{slug}"`.
  Future<OcwCourse> fetchCourse({
    required String courseId,
    required String slug,
  }) async {
    _log.info('fetchCourse: $courseId');
    final homeHtml = await _get('/courses/$slug/');
    final home = parseCourseHome(homeHtml, slug);

    final lectureRefs = <OcwLectureRef>[];
    if (home.videoGalleryPath != null) {
      final galleryHtml = await _get(home.videoGalleryPath!);
      lectureRefs.addAll(parseVideoGallery(galleryHtml, slug));
    }

    final lectures = await _fetchLectures(courseId, slug, lectureRefs);

    final resources = <OcwResource>[];
    if (home.lectureNotesPath != null) {
      final notesHtml = await _get(home.lectureNotesPath!);
      resources.addAll(parseLectureNotesPage(
        notesHtml,
        slug: slug,
        courseId: courseId,
      ));
    }

    final matched = matchResourcesToLectures(lectures, resources);

    return OcwCourse(
      id: courseId,
      slug: slug,
      title: home.title,
      courseNumber: home.courseNumber,
      description: home.description,
      imageUrl: home.imageUrl,
      sections: matched.lectures.isEmpty
          ? const []
          : [
              OcwSection(
                title: 'Video Lectures',
                order: 0,
                lectures: matched.lectures,
              ),
            ],
      orphanResources: matched.orphans,
    );
  }

  Future<List<OcwLecture>> _fetchLectures(
    String courseId,
    String slug,
    List<OcwLectureRef> refs,
  ) async {
    if (refs.isEmpty) return const [];
    final results = List<OcwLecture?>.filled(refs.length, null);
    var next = 0;

    Future<void> worker() async {
      while (true) {
        final idx = next++;
        if (idx >= refs.length) return;
        final ref = refs[idx];
        final path = '/courses/$slug/resources/${ref.slug}/';
        OcwLectureInfo info;
        try {
          final html = await _get(path);
          info = parseLecturePage(html);
        } on DioException catch (e) {
          _log.warning('lecture fetch failed $path: ${e.message}');
          info = OcwLectureInfo(title: ref.title);
        }
        final mp4 = info.mp4Url == null ? null : _normaliseMp4Url(info.mp4Url!);
        results[idx] = OcwLecture(
          id: '$courseId/${ref.slug}',
          slug: ref.slug,
          title: ref.title.isEmpty ? info.title : ref.title,
          sectionTitle: 'Video Lectures',
          sectionOrder: 0,
          lectureOrder: idx,
          mp4Url: mp4,
          durationSeconds: info.durationSeconds,
        );
      }
    }

    await Future.wait(
      List.generate(_lectureConcurrency, (_) => worker()),
    );
    return results.whereType<OcwLecture>().toList();
  }

  Future<String> _get(String path) async {
    final resp = await _dio.get<String>(
      path,
      options: Options(responseType: ResponseType.plain),
    );
    return resp.data ?? '';
  }
}

@Riverpod(keepAlive: true)
OcwCourseFetcher ocwCourseFetcher(Ref ref) => OcwCourseFetcher();
