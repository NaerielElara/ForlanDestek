import 'package:flutter/material.dart';

class ForlanServiceIndicator extends StatefulWidget {
  const ForlanServiceIndicator(
      {super.key, required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  State<ForlanServiceIndicator> createState() => _ForlanServiceIndicatorState();
}

class _ForlanServiceIndicatorState extends State<ForlanServiceIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
    value: 1,
  );

  void _syncAnimation() {
    if (widget.pulsing && !MediaQuery.of(context).disableAnimations) {
      _animation.repeat(reverse: true);
    } else {
      _animation.stop();
      _animation.value = 1;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ForlanServiceIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pulsing != widget.pulsing) _syncAnimation();
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 14,
      height: 14,
      child: AnimatedBuilder(
        animation: _animation,
        builder: (_, __) => Center(
          child: Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: widget.color.withOpacity(0.5 + 0.5 * _animation.value),
              boxShadow: [
                BoxShadow(
                    color:
                        widget.color.withOpacity(0.15 + 0.3 * _animation.value),
                    blurRadius: 4 + 6 * _animation.value,
                    spreadRadius: _animation.value),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
