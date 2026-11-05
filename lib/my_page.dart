import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'app_interactions.dart';
import 'app_ui.dart';
import 'bookmark_library_page.dart';
import 'reading_statistics_page.dart';
import 'catalog.dart';
import 'dock_layout.dart';
import 'feature_pages.dart';
import 'library_state.dart';
import 'offline_repository.dart';
import 'pages.dart' show SettingsPage;
import 'ui_notifiers.dart';
import 'updates/app_updates.dart';
import 'updates/update_page.dart';
import 'wenku8_storage_page.dart';

class MyPage extends StatelessWidget {
  const MyPage({
    super.key,
    required this.state,
    required this.repository,
    this.showHeader = true,
  });
  final LibraryState state;
  final NovelRepository repository;
  final bool showHeader;

  Widget buildHeader(BuildContext context) => const Align(
    alignment: Alignment.centerLeft,
    child: ArchiveMasthead(title: '我的', code: 'PERSONAL ARCHIVE'),
  );

  @override
  Widget build(BuildContext context) {
    final updates = AppUpdatesScope.maybeOf(context);
    return GlassHeaderLayout(
      showHeader: showHeader,
      header: buildHeader(context),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: ListView(
            key: const PageStorageKey('my-page'),
            padding: featurePadding(
              context,
            ).copyWith(bottom: DockLayout.scrollPaddingOf(context)),
            children: [
              const SizedBox(height: 24),
              FeatureEntry(
                key: const ValueKey('my-statistics'),
                title: '统计',
                subtitle: '阅读记录、藏书与书签',
                icon: CupertinoIcons.chart_bar,
                onTap: () => pushNovelPage<void>(
                  context,
                  ReadingStatisticsPage(state: state, repository: repository),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              ActiveListenableBuilder(
                listenable: state.bookmarkChanges,
                builder: (context) {
                  final count = libraryBookmarks(
                    state,
                    books: repository is OfflineNovelRepository
                        ? (repository as OfflineNovelRepository).local
                        : null,
                  ).length;
                  return FeatureEntry(
                    key: const ValueKey('my-bookmarks'),
                    title: '书签',
                    subtitle: count == 0 ? '收藏喜欢的句子与阅读位置' : '$count 条书签与摘录',
                    icon: CupertinoIcons.bookmark,
                    onTap: () => pushNovelPage<void>(
                      context,
                      BookmarkLibraryPage(state: state, repository: repository),
                      reduceMotion: state.reduceMotion,
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-settings'),
                title: '设置',
                subtitle: '阅读、外观、性能与本地数据',
                icon: CupertinoIcons.settings,
                onTap: () => pushNovelPage<void>(
                  context,
                  ArchiveFeaturePage(
                    title: '设置',
                    code: 'SYSTEM / PREFERENCES',
                    child: SettingsPage(
                      state: state,
                      repository: repository,
                      showHeader: false,
                    ),
                  ),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-storage'),
                title: '存储',
                subtitle: '下载临时文件与缓存占用',
                icon: CupertinoIcons.folder,
                onTap: () => pushNovelPage<void>(
                  context,
                  const Wenku8StoragePage(),
                  reduceMotion: state.reduceMotion,
                ),
              ),
              const SizedBox(height: 14),
              FeatureEntry(
                key: const ValueKey('my-about'),
                title: '关于',
                subtitle:
                    '版本 ${updates?.installed?.version ?? currentAppVersion}${updates?.available == true ? ' · 有新版本' : ''}',
                icon: CupertinoIcons.info_circle,
                onTap: () => pushNovelPage<void>(
                  context,
                  AppUpdatePage(updates: updates),
                  reduceMotion: state.reduceMotion,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
