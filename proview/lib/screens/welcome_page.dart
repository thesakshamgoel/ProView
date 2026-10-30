import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../clip_actions.dart';
import '../engine.dart';
import '../library.dart';
import '../theme.dart';
import '../toast.dart';
import '../ui/grid_pattern.dart';
import '../widgets.dart';
import '../ui/app_icons.dart';

/// First-run welcome and media permission.
class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});
  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  bool _askedOnce = false;

  Future<void> _allow() async {
    final result = await Library.instance.requestPermission();
    if (result == 'denied') {
      if (_askedOnce) {
        Toast.info('Turn on access in Settings', message: 'Permissions › Photos and videos › Allow');
        await Engine.call('openAppSettings');
      } else {
        Toast.error('ProView can\'t see your videos yet',
            message: 'You can still open single files, or allow access any time.');
      }
      setState(() => _askedOnce = true);
    } else if (result == 'partial') {
      Toast.info('Showing selected videos only', message: 'Allow all videos in Settings to see your full library.');
    } else {
      Toast.success('You\'re all set', message: 'Finding your videos');
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.groupedBackground,
      body: Stack(children: [
        const Positioned.fill(child: GridPattern()),
        SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(children: [
              Expanded(
                child: ListView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(28, 40, 28, 12),
                  children: [
                    const Center(child: LogoIntro(size: 128)),
                    const SizedBox(height: 28),
                    _Stagger(
                      delay: 500,
                      child: Text('Welcome to ProView', style: TextStyles.largeTitle(p), textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: 10),
                    _Stagger(
                      delay: 600,
                      child: Text(
                        'Pro video on your phone, the way it was shot.',
                        style: TextStyles.body(p).copyWith(color: p.secondaryLabel),
                        textAlign: TextAlign.center,
                      ),
                    ),
                    const SizedBox(height: 36),
                    _Stagger(
                      delay: 720,
                      child: _Feature(
                        icon: AppIcons.film,
                        color: p.accent,
                        title: 'Plays pro formats',
                        text: 'ProRes, HEVC 4:2:2 10-bit, DNxHR and more, decoded on the GPU and shown in 10-bit.',
                      ),
                    ),
                    _Stagger(
                      delay: 820,
                      child: _Feature(
                        icon: AppIcons.wand_stars,
                        color: p.purple,
                        title: 'Make clips phone-playable',
                        text: 'One tap makes a 10-bit copy that plays in Gallery and shares to WhatsApp.',
                      ),
                    ),
                    _Stagger(
                      delay: 920,
                      child: _Feature(
                        icon: AppIcons.archivebox_fill,
                        color: p.orange,
                        title: 'Phone, drives and cloud',
                        text: 'Your videos, USB-C SSDs, SD cards and Google Drive in one library.',
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
                child: _Stagger(
                  delay: 1050,
                  child: Column(children: [
                    GlassButton('Allow Access to Videos', prominent: true, onTap: _allow),
                    const SizedBox(height: 12),
                    GlassButton('Open a Single File', onTap: () => ClipActions.openFromPicker(context)),
                    const SizedBox(height: 14),
                    Text(
                      'ProView only reads your videos. Nothing leaves your phone.',
                      style: TextStyles.footnote(p),
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              ),
            ]),
          ),
        ),
        ),
      ]),
    );
  }
}

/// Fades and lifts its child in after [delay] ms (welcome screen choreography).
class _Stagger extends StatefulWidget {
  final int delay;
  final Widget child;
  const _Stagger({required this.delay, required this.child});
  @override
  State<_Stagger> createState() => _StaggerState();
}

class _StaggerState extends State<_Stagger> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  @override
  void initState() {
    super.initState();
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final a = CurvedAnimation(parent: _c, curve: Motion.emphasized);
    return FadeTransition(
      opacity: a,
      child: SlideTransition(position: Tween(begin: const Offset(0, 0.25), end: Offset.zero).animate(a), child: widget.child),
    );
  }
}

class _Feature extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String text;
  const _Feature({required this.icon, required this.color, required this.title, required this.text});
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        IconTile(icon, color, size: 40),
        const SizedBox(width: 16),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyles.headline(p)),
            const SizedBox(height: 2),
            Text(text, style: TextStyles.subhead(p).copyWith(color: p.secondaryLabel)),
          ]),
        ),
      ]),
    );
  }
}
