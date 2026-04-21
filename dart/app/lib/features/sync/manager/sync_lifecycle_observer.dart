import 'package:omnilect/features/sync/providers/sync_providers.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'sync_lifecycle_observer.g.dart';

/// Root-watched sentinel that ensures [syncManagerProvider] is instantiated
/// (and therefore auth-driven) for the lifetime of the app.
///
/// [syncManagerProvider] is keepAlive, but it only constructs the isolate +
/// bridges on first read. Without this observer, the first `ref.watch` from
/// a screen would be what triggers the isolate spawn, which means UI
/// callsites would see a null manager for the first frame after sign-in and
/// fire requests into the void. Reading this provider once at app startup
/// eliminates that race.
@Riverpod(keepAlive: true)
bool syncLifecycleObserver(Ref ref) {
  // Watch — not read — so auth transitions propagate: signing out disposes
  // syncManagerProvider, signing back in re-creates it.
  ref.watch(syncManagerProvider);
  return true;
}
