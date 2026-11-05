import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Desktop is mail-first for now: voice recognition and its models are off.
final isDesktop = Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// First crumb of every menu path, named after what home is on this device.
final homeLabel = isDesktop ? '메일 홈' : '홈';

/// A mail service's one-letter badge: white letter on its brand colour.
class ServiceBadge extends StatelessWidget {
  const ServiceBadge(this.mark, this.color, {super.key, this.size = 24});
  final String mark;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    alignment: Alignment.center,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    child: Text(
      mark,
      style: TextStyle(
        // Small badges need a relatively bigger letter to stay legible.
        fontSize: size < 20 ? size * 0.65 : size * 0.45,
        height: 1,
        fontWeight: FontWeight.w900,
        // The service's own mark, white as in its logo.
        color: Colors.white,
      ),
    ),
  );
}

/// Frosted white over whatever scrolls beneath: the dock, the mic and the
/// round back button. Solid white when the phone asks for more contrast.
class Glass extends StatelessWidget {
  const Glass({super.key, required this.child, this.radius = 22});
  final Widget child;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final round = BorderRadius.circular(radius);
    final solid = MediaQuery.highContrastOf(context);
    final face = DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: solid ? 1 : 0.72),
        borderRadius: round,
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.75),
          width: 0.5,
        ),
      ),
      child: child,
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: round,
        boxShadow: const [
          BoxShadow(
            color: Color(0x1f000000),
            blurRadius: 30,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: round,
        child: solid
            ? face
            : BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
                child: face,
              ),
      ),
    );
  }
}

/// White rounded group on the grey background, the base of every block.
class VoiceCard extends StatelessWidget {
  const VoiceCard({
    super.key,
    required this.child,
    this.color,
    this.borderColor,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final Color? color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(22);
    return Material(
      color: color ?? colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: borderColor == null
            ? BorderSide.none
            : BorderSide(color: borderColor!),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// [MenuRow]s as one white group with hairlines between them, as in iOS
/// settings.
class MenuGroup extends StatelessWidget {
  const MenuGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: VoiceCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, row) in children.indexed) ...[
            if (i > 0)
              Divider(
                height: 0.5,
                thickness: 0.5,
                indent: 60,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
            row,
          ],
        ],
      ),
    ),
  );
}

/// One row of a menu or settings list: [title] (and a lighter [note] beside
/// it) over [sub], with [trailing] on the right, or a chevron when it opens
/// a screen.
class MenuRow extends StatelessWidget {
  const MenuRow(
    this.title,
    this.sub, {
    super.key,
    this.note,
    this.icon,
    this.trailing,
    this.onTap,
  });

  final String title;
  final String? note;
  final String sub;
  final IconData? icon;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final row = Row(
      children: [
        // An ink tile holding the icon, as in iOS settings.
        if (icon != null) ...[
          Container(
            width: 30,
            height: 30,
            decoration: BoxDecoration(
              color: colors.primary,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 18, color: colors.onPrimary),
          ),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text.rich(
                TextSpan(
                  text: title,
                  children: [
                    if (note != null)
                      TextSpan(
                        text: ' $note',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
                style: const TextStyle(fontSize: 17),
              ),
              const SizedBox(height: 2),
              Text(
                sub,
                style: TextStyle(fontSize: 13, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        trailing ??
            (onTap == null
                ? const SizedBox.shrink()
                : Icon(Icons.chevron_right_rounded, color: colors.outline)),
      ],
    );
    // Inside a MenuGroup the group is the card; alone, the row is one.
    if (context.findAncestorWidgetOfExactType<MenuGroup>() != null) {
      return InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: row,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: VoiceCard(onTap: onTap, child: row),
    );
  }
}

/// Small grey label (none when empty) above an iOS large title.
class ScreenTitle extends StatelessWidget {
  const ScreenTitle(this.label, this.title, {super.key});
  final String label;
  final String title;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label,
            style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: 6),
        ],
        Text(
          title,
          style: const TextStyle(
            fontSize: 34,
            height: 1.2,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.7,
          ),
        ),
      ],
    );
  }
}

/// Frame of every screen but home: menu path, swipe back, floating button.
class AppPage extends StatefulWidget {
  const AppPage({
    super.key,
    required this.trail,
    required this.children,
    this.floating,
  });

  /// Menu path from home to this screen, shown top left.
  final List<String> trail;
  final List<Widget> children;

  /// Floats bottom centre over the content, e.g. the mail's reply pill.
  final Widget? floating;

  @override
  State<AppPage> createState() => _AppPageState();
}

class _AppPageState extends State<AppPage> {
  /// Set once a trackpad swipe has gone back, so one swipe pops one page.
  bool _swiped = false;

  // Mouse back button and two-finger swipe right go back, as in a browser.
  // ponytail: Flutter can't see gestures over the mail's WebView.
  void _onPointer(PointerEvent event) {
    switch (event) {
      case PointerDownEvent(:final buttons)
          when buttons & kBackMouseButton != 0:
        Navigator.maybePop(context);
      case PointerPanZoomStartEvent():
        _swiped = false;
      case PointerPanZoomUpdateEvent(:final pan)
          when !_swiped && pan.dx > 120 && pan.dx > pan.dy.abs() * 2:
        _swiped = true;
        Navigator.maybePop(context);
      default:
    }
  }

  /// A quick swipe right goes back. iOS already pops on an edge swipe, with
  /// the page following the finger, so it keeps that instead.
  void _onSwipe(DragEndDetails d) {
    if ((d.primaryVelocity ?? 0) > 300) Navigator.maybePop(context);
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: _onPointer,
    onPointerPanZoomStart: _onPointer,
    onPointerPanZoomUpdate: _onPointer,
    child: GestureDetector(
      onHorizontalDragEnd: Platform.isIOS ? null : _onSwipe,
      child: Scaffold(
        appBar: AppBar(
          toolbarHeight: 56,
          leadingWidth: 64,
          titleSpacing: 4,
          leading: Navigator.canPop(context) ? const _GlassBack() : null,
          title: _Trail(widget.trail),
        ),
        // Desktop windows: keep the column readable instead of edge to edge.
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            // Scrolls on under the floating dock, which the bottom padding
            // (the dock's height, set by home) clears at the end.
            child: ListView(
              padding: EdgeInsets.fromLTRB(
                20,
                4,
                20,
                24 + MediaQuery.paddingOf(context).bottom,
              ),
              children: widget.children,
            ),
          ),
        ),
        // Lifted off the bottom edge so a thumb reaches it without stretching.
        floatingActionButton: switch (widget.floating) {
          final pill? => Padding(
            padding: const EdgeInsets.only(bottom: 24),
            child: pill,
          ),
          null => null,
        },
        floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      ),
    ),
  );
}

/// Round white back button, top left of every screen but home.
class _GlassBack extends StatelessWidget {
  const _GlassBack();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(left: 16),
    // Plain white: the top bar is solid, so there is nothing to frost.
    child: Center(
      child: Material(
        color: Colors.white,
        shape: const CircleBorder(),
        elevation: 3,
        shadowColor: const Color(0x55000000),
        child: SizedBox.square(
          dimension: 44,
          child: IconButton(
            tooltip: '뒤로',
            onPressed: () => Navigator.maybePop(context),
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
          ),
        ),
      ),
    ),
  );
}

/// Breadcrumb like "메일 홈 › 메일 연동하기 › 네이버 메일". Each crumb is one
/// route on the stack, so tapping one pops back to it.
class _Trail extends StatelessWidget {
  const _Trail(this.trail);
  final List<String> trail;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: '현재 위치',
      child: Row(
        children: [
          for (final (i, crumb) in trail.indexed) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.onSurfaceVariant,
              ),
            Flexible(
              child: i == trail.length - 1
                  // Same side padding as the crumb buttons, so the gaps
                  // around each › match.
                  ? Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: Text(
                        crumb,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    )
                  : TextButton(
                      onPressed: () {
                        var back = trail.length - 1 - i;
                        Navigator.popUntil(context, (_) => back-- == 0);
                      },
                      style: TextButton.styleFrom(
                        foregroundColor: colors.onSurfaceVariant,
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        minimumSize: const Size(0, 40),
                        // The 48 tap target widened short crumbs like "홈".
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: const TextStyle(fontSize: 15),
                      ),
                      child: Text(crumb, overflow: TextOverflow.ellipsis),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Ink pill floating over a screen: write a mail or reply, or say one.
class WritePill extends StatelessWidget {
  const WritePill(
    this.label, {
    super.key,
    required this.onWrite,
    this.icon = Icons.edit_square,
    this.onVoice,
    this.voiceIcon = Icons.mic_none_rounded,
    this.voiceLabel,
  });
  final String label;
  final IconData icon;
  final VoidCallback onWrite;

  /// Null hides the right-hand part (the mic, unless [voiceIcon] says else).
  final VoidCallback? onVoice;
  final IconData voiceIcon;

  /// Shown beside [voiceIcon]; without it the icon stands alone.
  final String? voiceLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.primary,
      shape: const StadiumBorder(),
      elevation: 6,
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: onWrite,
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                22,
                10,
                onVoice == null ? 22 : 16,
                10,
              ),
              child: Row(
                children: [
                  Icon(icon, color: colors.onPrimary),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                      color: colors.onPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (onVoice != null) ...[
            Container(
              width: 1,
              height: 22,
              color: colors.onPrimary.withValues(alpha: 0.24),
            ),
            InkWell(
              onTap: onVoice,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 20, 10),
                child: Semantics(
                  label: voiceLabel ?? '말로 $label',
                  child: Row(
                    children: [
                      Icon(voiceIcon, color: colors.inversePrimary),
                      if (voiceLabel case final text?) ...[
                        const SizedBox(width: 6),
                        Text(
                          text,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: colors.inversePrimary,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small pill beside a mail service: 연결됨, 연결 안 됨 or 곧 지원.
class StatusChip extends StatelessWidget {
  const StatusChip(this.label, this.color, {super.key});
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: color.withValues(alpha: 0.5)),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
    ),
  );
}

/// Drops notifications after dispose: a load or download can finish after
/// the home screen that owned it is gone.
mixin SafeNotifier on ChangeNotifier {
  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Logo lockup at the top of home.
class Brand extends StatelessWidget {
  const Brand({super.key});

  // Lockup from design/logo, black "alpha-" and [accent] "mail", as in the
  // blue-accent drafts.
  @override
  Widget build(BuildContext context) => Image.asset(
    'assets/brand/logo-horizontal-accent.png',
    height: 34,
    // The 600×160 source shrinks ~2–5×; the default low filter skips pixels
    // at that ratio and left the curves jagged. Medium samples mipmaps.
    filterQuality: FilterQuality.medium,
    semanticLabel: 'Alpha-mail',
  );
}
