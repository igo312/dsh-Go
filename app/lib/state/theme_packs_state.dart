// The theme packs installed on this phone: where they live
// (`<app support>/themes`), the list the settings page shows, and the
// install / remove actions behind it. Choosing one and applying its palette
// belong to `state/appearance_state.dart`; this file only owns the library.
//
// Installs, removals and listings go through [ThemePackLibrary], which runs
// them one at a time and keeps a broken archive out of the list. A listing
// that cannot be read is an error state, never an empty list.

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../theme_packs/theme_pack.dart';
import '../theme_packs/theme_pack_library.dart';

export '../theme_packs/theme_pack_library.dart' show ThemePackInstallation, ThemePackInspection;

/// Where the library reads and writes. A function, so the platform directory
/// is asked for only when the library is first used (and tests can point it
/// at a temporary folder).
final themePackRootProvider = Provider<Future<Directory> Function()>(
  (ref) =>
      () async => Directory('${(await getApplicationSupportDirectory()).path}/themes'),
);

/// The library under [themePackRootProvider].
///
/// No automatic retries: a folder that cannot be listed (permissions, the
/// platform directory unavailable) is not fixed by re-reading it a few times,
/// and the launch screen would wait through every attempt.
final themePackLibraryProvider = FutureProvider<ThemePackLibrary>(
  (ref) async => ThemePackLibrary(await ref.watch(themePackRootProvider)()),
  retry: (_, _) => null,
);

/// Every installed theme pack, newest state after each install / removal.
final installedThemePacksProvider = AsyncNotifierProvider<InstalledThemePacksController, List<ThemePackInstallation>>(
  InstalledThemePacksController.new,
  retry: (_, _) => null,
);

class InstalledThemePacksController extends AsyncNotifier<List<ThemePackInstallation>> {
  @override
  Future<List<ThemePackInstallation>> build() async {
    final library = await ref.watch(themePackLibraryProvider.future);
    return library.list();
  }

  /// Installs [inspection] (replacing a pack with the same id) and lists the
  /// library again. A failure leaves the state as it was and is rethrown for
  /// the page to show.
  Future<({ThemePack pack, bool replaced})> install(ThemePackInspection inspection) async {
    final library = await ref.read(themePackLibraryProvider.future);
    final result = await library.install(inspection);
    await reload();
    return result;
  }

  /// Removes the pack with [id] and lists the library again.
  Future<void> remove(String id) async {
    final library = await ref.read(themePackLibraryProvider.future);
    await library.remove(id);
    await reload();
  }

  /// Lists the library again; a read failure becomes the error state.
  Future<void> reload() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final library = await ref.read(themePackLibraryProvider.future);
      return library.list();
    });
  }
}
