/// Paper treatments for the home-screen reading widgets.
///
/// The reference snapshot did not ship the original skin catalogue, so this
/// build provides a small, deterministic palette set. Unknown or legacy ids
/// fall back to [original], which keeps stored configurations readable.
enum ReadingWidgetSkin {
  original('原样', '朴素纸面', 0xFFF6F1E7, 0xFF2A2622),
  seasons('四季', '随季节变换的纸色', 0xFFEDE7D9, 0xFF33302A),
  spring('春晓', '新叶初生的浅绿', 0xFFE8F0E3, 0xFF2C3A2A),
  summer('夏夜', '沉入夜色的深青', 0xFF1E2A2E, 0xFFE6EFEE),
  autumn('秋叶', '被晒暖的旧纸', 0xFFF3E4D2, 0xFF3A2B20),
  winter('冬雪', '安静的冷白', 0xFFEFF2F6, 0xFF2A2F38),
  glass('玻璃', '半透明的雾面', 0xFFE9EDF2, 0xFF2B3138);

  const ReadingWidgetSkin(this.label, this.description, this.paper, this.ink);

  final String label;
  final String description;

  /// Base paper colour (ARGB) used by previews and rendered cards.
  final int paper;

  /// Base ink colour (ARGB) used by previews and rendered cards.
  final int ink;

  static ReadingWidgetSkin fromId(String? value) =>
      values.where((skin) => skin.name == value).firstOrNull ?? original;
}

/// Clamps a stored daily reading goal to the supported range.
///
/// `0` means "no goal". Values outside 1–1440 minutes are treated as no goal so
/// a corrupt preference can never break the widget surface.
int readingDailyGoal(int? minutes) {
  if (minutes == null || minutes <= 0 || minutes > 1440) return 0;
  return minutes;
}