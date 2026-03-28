import 'package:flutter/material.dart';

class ExpressiveIndicator extends StatefulWidget {
  const ExpressiveIndicator({
    this.color = Colors.white,
    this.strokeWidth = 3.0,
    this.size = 20.0,
    super.key,
  });

  final Color color;
  final double strokeWidth;
  final double size;

  @override
  State<ExpressiveIndicator> createState() => _ExpressiveIndicatorState();
}

class _ExpressiveIndicatorState extends State<ExpressiveIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
    _scale = TweenSequence<double>(<TweenSequenceItem<double>>[
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.08), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.08, end: 0.94), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 0.94, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: ScaleTransition(
        scale: _scale,
        child: CircularProgressIndicator(
          strokeWidth: widget.strokeWidth,
          valueColor: AlwaysStoppedAnimation<Color>(widget.color),
          backgroundColor: widget.color.withValues(alpha: 0.24),
        ),
      ),
    );
  }
}
