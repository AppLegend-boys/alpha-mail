import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'speech.dart';

void main() {
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks([
      'Gowun Batang',
    ], await rootBundle.loadString('assets/fonts/OFL.txt'));
  });
  runApp(const AlphaMailApp());
}

// Night voice mode: high-contrast dark with one mint accent, for glancing
// at while driving. Dark only: the app ignores the phone's theme setting.
ThemeData _theme() {
  const scheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Color(0xffa8f5d0),
    onPrimary: Color(0xff0d111b),
    primaryContainer: Color(0xff1b3a33),
    onPrimaryContainer: Color(0xffa8f5d0),
    secondary: Color(0xffa8f5d0),
    onSecondary: Color(0xff0d111b),
    tertiary: Color(0xfff2a93b),
    onTertiary: Color(0xff1d1407),
    error: Color(0xffff7a6b),
    onError: Color(0xff2a0b07),
    surface: Color(0xff0d111b),
    onSurface: Color(0xfff5f7fa),
    onSurfaceVariant: Color(0xff9ba7b7),
    surfaceContainer: Color(0xff151b26),
    outline: Color(0xff5d6878),
    outlineVariant: Color(0xff252e3d),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xff0d111b),
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: const DrawerThemeData(backgroundColor: Color(0xff0d111b)),
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

class AlphaMailApp extends StatelessWidget {
  const AlphaMailApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Alpha Mail',
    debugShowCheckedModeBanner: false,
    theme: _theme(),
    home: const SpeechScreen(),
  );
}
