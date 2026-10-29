import 'package:flutter/material.dart';

import '../mail/mail.dart';
import '../widgets.dart';

/// Home's menu: inside the drawer on phones, the sidebar on wide windows.
/// A folded [sidebar] shows icons only, with the label as a tooltip.
class HomeMenu extends StatelessWidget {
  const HomeMenu({
    super.key,
    this.sidebar = false,
    required this.railOnly,
    required this.onToggleRail,
    required this.section,
    required this.linked,
    required this.onHome,
    required this.onFolder,
    required this.onVoice,
    required this.onConnect,
    required this.onSettings,
    required this.onOffline,
  });

  final bool sidebar;

  /// Sidebar shrunk to an icon rail (wide windows only).
  final bool railOnly;
  final VoidCallback onToggleRail;

  /// Menu item lit up: 'home', a [MailFolder] name, 'voice', 'settings' or
  /// 'offline'.
  final String section;

  /// Some mail account is linked, so the folders show instead of 메일 연동하기.
  final bool linked;
  final VoidCallback onHome;
  final void Function(MailFolder folder) onFolder;
  final VoidCallback onVoice;
  final VoidCallback onConnect;
  final VoidCallback onSettings;
  final VoidCallback onOffline;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final rail = sidebar && railOnly;
    Widget item(
      String label, {
      required IconData icon,
      bool selected = false,
      Color? iconColor,
      required VoidCallback onTap,
    }) {
      // A ListTile with no room for a title throws in layout, so the rail
      // uses plain icon buttons.
      if (rail) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: IconButton(
            tooltip: label,
            onPressed: onTap,
            icon: Icon(icon),
            style: IconButton.styleFrom(
              minimumSize: const Size.fromHeight(52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              backgroundColor: selected ? colors.primaryContainer : null,
              foregroundColor: selected
                  ? colors.onPrimaryContainer
                  : iconColor ?? colors.onSurfaceVariant,
            ),
          ),
        );
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: ListTile(
          selected: selected,
          selectedTileColor: colors.primaryContainer,
          selectedColor: colors.onPrimaryContainer,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          leading: Icon(
            icon,
            color: selected ? null : iconColor ?? colors.onSurfaceVariant,
          ),
          minLeadingWidth: 10,
          title: Text(
            label,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
          onTap: onTap,
        ),
      );
    }

    final toggle = IconButton(
      tooltip: rail ? '메뉴 펼치기' : '메뉴 접기',
      icon: Icon(rail ? Icons.menu_rounded : Icons.menu_open_rounded),
      onPressed: onToggleRail,
    );
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (rail)
              toggle
            else
              Row(
                children: [
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 6),
                    child: Brand(),
                  ),
                  const Spacer(),
                  if (sidebar) toggle,
                ],
              ),
            Divider(height: 28, color: colors.outlineVariant),
            item(
              homeLabel,
              icon: Icons.home_rounded,
              selected: section == 'home',
              onTap: onHome,
            ),
            if (linked)
              for (final (folder, icon) in [
                (MailFolder.all, Icons.inbox_rounded),
                (MailFolder.unread, Icons.mark_email_unread_outlined),
                (MailFolder.sent, Icons.send_outlined),
              ])
                item(
                  folder.label,
                  icon: icon,
                  selected: section == folder.name,
                  onTap: () => onFolder(folder),
                ),
            Divider(height: 20, color: colors.outlineVariant),
            if (!isDesktop)
              item(
                '음성 설정',
                icon: Icons.graphic_eq_rounded,
                selected: section == 'voice',
                onTap: onVoice,
              ),
            // A call to action until an account is linked; after that the
            // accounts live in 앱 설정.
            if (!linked)
              if (rail)
                item(
                  '메일 연동하기',
                  icon: Icons.add_rounded,
                  iconColor: colors.primary,
                  onTap: onConnect,
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: OutlinedButton.icon(
                    onPressed: onConnect,
                    icon: const Icon(Icons.add_rounded),
                    label: const Text('메일 연동하기'),
                    style: OutlinedButton.styleFrom(
                      alignment: Alignment.centerLeft,
                      minimumSize: const Size.fromHeight(52),
                      foregroundColor: colors.primary,
                      backgroundColor: colors.primaryContainer.withValues(
                        alpha: 0.4,
                      ),
                      side: BorderSide(
                        color: colors.primary.withValues(alpha: 0.5),
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
            item(
              '앱 설정',
              icon: Icons.settings_outlined,
              selected: section == 'settings',
              onTap: onSettings,
            ),
            item(
              '오프라인 화면 미리보기',
              icon: Icons.cloud_off_rounded,
              selected: section == 'offline',
              onTap: onOffline,
            ),
            const Spacer(),
            if (!isDesktop && !rail)
              VoiceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '음성 프라이버시',
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '음성 원본은 기기 안에서 인식해요.',
                      style: TextStyle(
                        fontSize: 13,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
