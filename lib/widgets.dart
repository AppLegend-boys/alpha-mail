import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Amber for offline / waiting states (design 06).
const amber = Color(0xfff2a93b);
const amberCard = Color(0xfffff1dc);

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
        color: Colors.white,
      ),
    ),
  );
}

/// Rounded dark card with a hairline border, the base of every block.
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
    final radius = BorderRadius.circular(14);
    return Material(
      color: color ?? colors.surfaceContainer,
      shape: RoundedRectangleBorder(
        borderRadius: radius,
        side: BorderSide(color: borderColor ?? colors.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// Small grey label above a big white title, as on every design screen.
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
        Text(
          label,
          style: TextStyle(fontSize: 14, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Text(
          title,
          style: const TextStyle(
            fontSize: 28,
            height: 1.35,
            fontWeight: FontWeight.w800,
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
        // Shorter than the default 56 so the back button and path sit as
        // high as the home's logo row.
        appBar: AppBar(
          toolbarHeight: 48,
          leadingWidth: 48,
          titleSpacing: 0,
          title: _Trail(widget.trail),
        ),
        body: SafeArea(
          top: false,
          // Desktop windows: keep the column readable instead of edge to edge.
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
                children: widget.children,
              ),
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

/// Black pill floating over a screen: write a mail or reply, or say one.
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
            Container(width: 1, height: 22, color: Colors.white24),
            InkWell(
              onTap: onVoice,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 20, 10),
                child: Semantics(
                  label: voiceLabel ?? '말로 $label',
                  child: Row(
                    children: [
                      Icon(voiceIcon, color: const Color(0xffc5c0ff)),
                      if (voiceLabel case final text?) ...[
                        const SizedBox(width: 6),
                        Text(
                          text,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Color(0xffc5c0ff),
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

/// Logo lockup, shared by the home bar and the drawer.
/// The symbol's drop of blue: "mail" in the logo and the unread count.
const accent = Color(0xff1d5bd6);

/// Light blue for the mic icon on black.
const voiceBlue = Color(0xff8db4ff);

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
