/// Event name and parameter key constants for Firebase Analytics.
///
/// All names use snake_case per Firebase GA4 convention. No vendor prefix.
library;

// ---------------------------------------------------------------------------
// Event names
// ---------------------------------------------------------------------------

const kEventAppOpen = 'app_open';
const kEventLoginSuccess = 'login_success';
const kEventLoginFailure = 'login_failure';
const kEventLogout = 'logout';

const kEventSyncStart = 'sync_start';
const kEventSyncComplete = 'sync_complete';
const kEventSyncFailure = 'sync_failure';

const kEventDownloadStart = 'download_start';
const kEventDownloadComplete = 'download_complete';
const kEventDownloadFailure = 'download_failure';

const kEventCourseView = 'course_view';
const kEventSectionOpen = 'section_open';
const kEventSectionPlay = 'section_play';

const kEventOnboardingListSelectionCompleted =
    'onboarding_list_selection_completed';
const kEventSettingsListSelectionChanged = 'settings_list_selection_changed';

const kEventVideoPlay = 'video_play';
const kEventVideoPause = 'video_pause';
const kEventVideoComplete = 'video_complete';
const kEventVideoScrub = 'video_scrub';

const kEventContinueResume = 'continue_resume';

// ---------------------------------------------------------------------------
// Parameter keys
// ---------------------------------------------------------------------------

const kParamPlatform = 'platform';
const kParamAppVersion = 'app_version';
const kParamIsFirstOpen = 'is_first_open';

const kParamMethod = 'method';
const kParamReason = 'reason';
const kParamStage = 'stage';

const kParamScope = 'scope';
const kParamCourseId = 'course_id';
const kParamBlockId = 'block_id';
const kParamVideoBlockId = 'video_block_id';
const kParamTrigger = 'trigger';

const kParamDurationMs = 'duration_ms';
const kParamItemsSynced = 'items_synced';
const kParamErrorKind = 'error_kind';

const kParamVideoCount = 'video_count';
const kParamBytesDownloaded = 'bytes_downloaded';
const kParamVideosCompleted = 'videos_completed';
const kParamVideosTotal = 'videos_total';

const kParamSource = 'source';
const kParamSectionIndex = 'section_index';

const kParamListCount = 'list_count';
const kParamHasAllEnrolled = 'has_all_enrolled';
const kParamHasMyLists = 'has_my_lists';
const kParamAvailableCount = 'available_count';
const kParamListsAdded = 'lists_added';
const kParamListsRemoved = 'lists_removed';

const kParamPositionS = 'position_s';
const kParamFromPositionS = 'from_position_s';
const kParamToPositionS = 'to_position_s';
const kParamDurationS = 'duration_s';
const kParamIsResume = 'is_resume';

const kParamLectureId = 'lecture_id';
const kParamPositionSeconds = 'position_seconds';

const kPlatformMitx = 'mitx';
const kPlatformOcw = 'ocw';

// ---------------------------------------------------------------------------
// Enum-like string values
// ---------------------------------------------------------------------------

const kScopeAllCourses = 'all_courses';
const kScopeCourse = 'course';
const kScopeSection = 'section';
const kScopeVideo = 'video';

const kTriggerManual = 'manual';
const kTriggerAuto = 'auto_on_open';
const kTriggerPullToRefresh = 'pull_to_refresh';

const kSourceCourseList = 'course_list';
