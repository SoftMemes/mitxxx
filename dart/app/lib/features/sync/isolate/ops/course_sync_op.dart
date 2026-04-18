import 'dart:async';

import 'package:omnilect/features/sync/isolate/ops/course_sync_runner.dart';
import 'package:omnilect/features/sync/isolate/ops/logical_op.dart';
import 'package:omnilect/features/sync/isolate/ops/op_context.dart';

class CourseSyncOp extends LogicalOp {
  CourseSyncOp({
    required super.request,
    required super.cancelToken,
    required super.events,
    required this.ctx,
    required this.courseId,
  });

  final OpContext ctx;
  final String courseId;

  @override
  Future<void> run() async {
    final runtime = OpRuntime(ctx: ctx, token: cancelToken, events: events);
    await syncSingleCourse(runtime, courseId: courseId, trigger: trigger);
  }
}
