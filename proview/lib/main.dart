import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'clip_actions.dart';
import 'engine.dart';
import 'library.dart';
import 'perf.dart';
import 'screens/home_shell.dart';
import 'screens/welcome_page.dart';
import 'tasks.dart';
import 'theme.dart';
import 'toast.dart';
import 'widgets.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // Browsing is portrait (like the iPhone apps); the player unlocks rotation while it's open.
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  TaskCenter.instance.start();
  FramePerf.start();
  runApp(const ProViewApp());
}

class ProViewApp extends StatelessWidget {
  const ProViewApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ProView',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      theme: buildTheme(Palette.light),
      darkTheme: buildTheme(Palette.dark),
      themeMode: ThemeMode.system,
      builder: (context, child) => Toast.host(child: child!),
      home: const _Root(),
    );
  }
}

class _Root extends StatefulWidget {
  const _Root();
  @override
  State<_Root> createState() => _RootState();
}

class _RootState extends State<_Root> with WidgetsBindingObserver {
  StreamSubscription<BgTask>? _finished;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Engine.onOpenUri(_open);
    _finished = TaskCenter.instance.finished.listen(_onFinished);
    Library.instance.init().then((_) async {
      final uri = await Engine.call<String>('initialUri');
      if (uri != null) _open(uri);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _finished?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pick up new videos, drives plugged in and permission changes when returning to the app.
    if (state == AppLifecycleState.resumed && Library.instance.loaded) Library.instance.refresh();
  }

  void _open(String uri) {
    // A clip opened from outside replaces whatever is playing instead of stacking a second player.
    navigatorKey.currentState?.popUntil((r) => r.isFirst);
    final ctx = navigatorKey.currentContext;
    if (ctx != null) ClipActions.openUri(ctx, uri);
  }

  void _onFinished(BgTask t) {
    if (t.type == 'convert' && t.state == TaskState.done) {
      Toast.success('Ready to play',
          message: '${t.outputName ?? t.title} is in Gallery › ProView.',
          actionLabel: 'Play',
          onAction: () => t.outputUri == null ? null : _open(t.outputUri!));
    } else if (t.type == 'convert' && t.state == TaskState.failed) {
      Toast.error('Conversion failed', message: '${t.title}: ${t.error ?? 'unknown error'}');
    } else if (t.type == 'download' && t.state == TaskState.failed) {
      Toast.error('Download failed', message: t.error ?? t.title);
    }
  }

  @override
  Widget build(BuildContext context) {
    final lib = Library.instance;
    return ListenableBuilder(
      listenable: lib,
      builder: (context, _) {
        final Widget page;
        if (!lib.loaded) {
          page = Scaffold(
            key: const ValueKey('loading'),
            backgroundColor: Palette.of(context).groupedBackground,
            body: const Center(child: LogoSpinner(size: 72)),
          );
        } else if (lib.permission == 'denied' && lib.documents.isEmpty) {
          page = const WelcomePage(key: ValueKey('welcome'));
        } else {
          page = const HomeShell(key: ValueKey('home'));
        }
        return AnimatedSwitcher(
          duration: Motion.medium,
          switchInCurve: Motion.emphasized,
          transitionBuilder: (child, a) => FadeTransition(
            opacity: a,
            child: ScaleTransition(scale: Tween(begin: 1.03, end: 1.0).animate(a), child: child),
          ),
          child: page,
        );
      },
    );
  }
}
