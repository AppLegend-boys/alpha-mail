import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens.dart';
import 'speech.dart';

void main() {
  // SystemChrome below talks to the platform, which needs the binding.
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Gowun Batang',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  // Android: hide the system navigation bar (a swipe up shows it for a
  // moment); keep the status bar.
  if (defaultTargetPlatform == TargetPlatform.android) {
    SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: [SystemUiOverlay.top],
    );
  }
  runApp(const AlphaMailApp());
}

// Light grey background, white cards, black text, black symbol
// for the logo and main buttons. One theme: the app ignores the phone's
// dark mode setting.
const background = Color(0xffeeeeee);
const ink = Color(0xff000000);
const symbol = ink;

ThemeData _theme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: symbol,
    onPrimary: Color(0xffffffff),
    primaryContainer: Color(0xffe0e0e0),
    onPrimaryContainer: symbol,
    secondary: ink,
    onSecondary: Color(0xffffffff),
    tertiary: Color(0xfff2a93b),
    onTertiary: Color(0xff1d1407),
    error: Color(0xffd93a2b),
    onError: Color(0xffffffff),
    surface: background,
    onSurface: ink,
    onSurfaceVariant: Color(0xff555555),
    surfaceContainer: Color(0xffffffff),
    outline: Color(0xff8a8a8a),
    outlineVariant: Color(0xffd6d6d6),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: background,
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: background),
    snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(56),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class AlphaMailApp extends StatefulWidget {
  const AlphaMailApp({super.key});

  @override
  State<AlphaMailApp> createState() => _AlphaMailAppState();
}

class _AlphaMailAppState extends State<AlphaMailApp> {
  // Phones only: Android 12+ lets an icon theme (Samsung) replace the system
  // splash icon, so the brand screen is drawn here, over the home loading
  // underneath.
  bool _splash = !isDesktop;

  @override
  void initState() {
    super.initState();
    if (_splash) {
      Future.delayed(const Duration(milliseconds: 1400), () {
        if (mounted) setState(() => _splash = false);
      });
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Alpha Mail',
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: Stack(
      children: [
        const SpeechScreen(),
        IgnorePointer(
          ignoring: !_splash,
          child: AnimatedOpacity(
            opacity: _splash ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: const _Splash(),
          ),
        ),
      ],
    ),
  );
}

/// Grey screen with the brown lockup and the app's promise.
class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Image.asset(
              'assets/brand/logo-horizontal.png',
              width: 220,
              // The asset is mint; tint it to the symbol colour.
              color: colors.primary,
              filterQuality: FilterQuality.medium,
              semanticLabel: 'Alpha-mail',
            ),
            const SizedBox(height: 20),
            Text(
              '메일을 듣고 말로 답장하세요',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
