import 'package:flutter_test/flutter_test.dart';
import 'package:omnilect/features/progress/services/progress_tracker.dart';

void main() {
  group('isLectureComplete', () {
    test('true within 2s of duration', () {
      expect(isLectureComplete(58, 60), isTrue);
      expect(isLectureComplete(60, 60), isTrue);
      expect(isLectureComplete(100, 100.5), isTrue);
    });

    test('false when more than 2s remain', () {
      expect(isLectureComplete(57.9, 60), isFalse);
      expect(isLectureComplete(0, 60), isFalse);
    });

    test('false when duration unknown (<= 0)', () {
      expect(isLectureComplete(10, 0), isFalse);
      expect(isLectureComplete(10, -1), isFalse);
    });

    test('handles very short lectures', () {
      // Any non-zero position on a 1.5s video counts as complete: 1.5 - 2 = -0.5
      // and position >= -0.5 is always true for non-negative positions.
      expect(isLectureComplete(0, 1.5), isTrue);
      expect(isLectureComplete(1.5, 1.5), isTrue);
    });
  });
}
