// Patrol-driven UI tests. The PATROL_INTEGRATION_TEST_IOS_RUNNER macro
// expands into the XCTest glue that runs the Dart-side integration tests.
//
// Two flags must be defined *before* the macro expands (they're used as
// numeric expressions inside the expansion, not `#ifdef`-guarded):
//
//   CLEAR_PERMISSIONS  — reset iOS protected-resource authorizations
//                         between tests (0 = skip, 1 = reset).
//   FULL_ISOLATION     — uninstall + reinstall the app between tests
//                         (0 = keep install, 1 = reinstall each test).
//
// Both off for our screenshot run: it's a single test and re-installing
// would blow away the Dart-side state we just walked through.
#define CLEAR_PERMISSIONS 0
#define FULL_ISOLATION 0

@import XCTest;
@import patrol;
@import ObjectiveC.runtime;

PATROL_INTEGRATION_TEST_IOS_RUNNER(RunnerUITests)
