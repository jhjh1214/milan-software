/// A small breathing cluster of dots -- "AI is working on this," beside the
/// text that already says so. Never the only signal: every call site keeps
/// its own label text beside this, the same rule the app's `.spinner`-style
/// `CircularProgressIndicator` uses elsewhere already keeps.
///
/// SPEC.md §14.7: a recognition proposal is never production truth, and this
/// widget is purely cosmetic -- it carries no state about what the request
/// will return, only that one is in flight.
///
/// The first hand-built animation in this app (every other loading state
/// uses `CircularProgressIndicator`'s own indeterminate spin). Kept simple on
/// purpose: a single `AnimationController` driving three dots at staggered
/// offsets, rather than reaching for a package for something this small.
library;

import 'package:flutter/material.dart';

import '../theme.dart';

class AiThinkingIndicator extends StatefulWidget {
  const AiThinkingIndicator({super.key});

  @override
  State<AiThinkingIndicator> createState() => _AiThinkingIndicatorState();
}

class _AiThinkingIndicatorState extends State<AiThinkingIndicator>
    with SingleTickerProviderStateMixin {
  static const _period = Duration(milliseconds: 1200);

  late final AnimationController _controller;
  // Null until the first `didChangeDependencies` -- not `false` -- so the
  // common (non-reduced) case still starts the controller on that first
  // call rather than being skipped by an unchanged-value check.
  bool? _reduceMotion;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _period);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // `MediaQuery` is not available in `initState`, only from here on. A
    // reduced-motion request holds the dots at a static, still-visible
    // frame rather than looping -- nothing else in this app reads this
    // signal yet, so this is a genuinely new case, not a cosmetic one.
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (reduceMotion == _reduceMotion) return;
    _reduceMotion = reduceMotion;
    if (reduceMotion) {
      _controller.stop();
    } else {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 8,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _dot(0.0),
          const SizedBox(width: 4),
          _dot(0.15),
          const SizedBox(width: 4),
          _dot(0.3),
        ],
      ),
    );
  }

  Widget _dot(double delayFraction) {
    if (_reduceMotion ?? false) {
      return const _Dot(scale: 0.8, opacity: 0.8);
    }
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(delayFraction, 1.0, curve: Curves.easeInOut),
    );
    return AnimatedBuilder(
      animation: curve,
      builder: (context, _) {
        // A 0..1..0 pulse across the interval: scale/opacity both breathe
        // rather than snapping, matching the dashboard's own CSS keyframe
        // (`.thinking-dots`, `styles.css`) so the two feel like one design.
        final t = curve.value;
        final pulse = t < 0.5 ? t * 2 : (1 - t) * 2;
        return _Dot(scale: 0.6 + 0.4 * pulse, opacity: 0.4 + 0.6 * pulse);
      },
    );
  }
}

class _Dot extends StatelessWidget {
  final double scale;
  final double opacity;

  const _Dot({required this.scale, required this.opacity});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Container(
          width: 6,
          height: 6,
          decoration: const BoxDecoration(
            color: AppColors.primary,
            shape: BoxShape.circle,
          ),
        ),
      ),
    );
  }
}
