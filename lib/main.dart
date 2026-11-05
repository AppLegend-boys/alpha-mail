import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Gowun Batang',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  // enough_mail prints an error for each EUC-KR header and body it can't
  // read; koreanHeader and koreanText in mail_account.dart read those.
  final korean = RegExp(r'no encoding found for .*\[(euc-kr|ks_c_5601|cp949)');
  runZoned(
    () {
      // SystemChrome below talks to the platform, which needs the binding.
      WidgetsFlutterBinding.ensureInitialized();
      // Android: hide the system navigation bar (a swipe up shows it for a
      // moment); keep the status bar.
      if (defaultTargetPlatform == TargetPlatform.android) {
        SystemChrome.setEnabledSystemUIMode(
          SystemUiMode.manual,
          overlays: [SystemUiOverlay.top],
        );
      }
      runApp(const AlphaMailApp());
    },
    zoneSpecification: ZoneSpecification(
      print: (self, parent, zone, line) {
        if (!korean.hasMatch(line.toLowerCase())) parent.print(zone, line);
      },
    ),
  );
}

// Grouped grey background, white rounded groups, black text and one
// fountain-pen ink for buttons, the selected tab and the mic. One theme:
// the app ignores the phone's dark mode setting.
const background = Color(0xfff2f2f7);
const ink = Color(0xff000000);
const penInk = Color(0xff2d3e8c);

ThemeData _theme() {
  const scheme = ColorScheme(
    brightness: Brightness.light,
    primary: penInk,
    onPrimary: Color(0xffffffff),
    // Ink at 12% on white: chips, the selected row, tonal buttons.
    primaryContainer: Color(0xffe3e5f0),
    onPrimaryContainer: penInk,
    // The unread count, in the same ink.
    secondary: penInk,
    onSecondary: Color(0xffffffff),
    // Tonal buttons like 나중에: the ink tint, not a second solid ink.
    secondaryContainer: Color(0xffe3e5f0),
    onSecondaryContainer: penInk,
    tertiary: Color(0xfff2a93b),
    onTertiary: Color(0xff1d1407),
    error: Color(0xffd93a2b),
    onError: Color(0xffffffff),
    surface: background,
    onSurface: ink,
    // iOS's grey label, darkened to keep 4.5:1 on the grey background.
    onSurfaceVariant: Color(0xff6c6c70),
    surfaceContainer: Color(0xffffffff),
    outline: Color(0xff8a8a8e),
    outlineVariant: Color(0xffd1d1d6),
    // Voice controls on the ink write pill.
    inversePrimary: Color(0xffc9d2f5),
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
    chipTheme: const ChipThemeData(
      shape: StadiumBorder(),
      side: BorderSide.none,
      backgroundColor: Color(0xffffffff),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(50),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
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
        const HomeScreen(),
        IgnorePointer(
          ignoring: !_splash,
          child: AnimatedOpacity(
            opacity: _splash ? 1 : 0,
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 300),
            child: const _Splash(),
          ),
        ),
      ],
    ),
  );
}

/// Grey screen with the black lockup and the app's promise.
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
              // The asset is mint; tint it black, like the text.
              color: colors.onSurface,
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
