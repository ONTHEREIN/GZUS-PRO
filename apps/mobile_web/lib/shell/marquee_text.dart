// 跑马灯文本部件（自 main.dart 拆分）。part of main.dart 共享同一 library。
part of '../main.dart';

class MarqueeText extends StatefulWidget {
  const MarqueeText({
    super.key,
    required this.text,
    this.style,
    this.scrollSpeed = 30.0,
  });

  final String text;
  final TextStyle? style;
  final double scrollSpeed;

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  double _textWidth = 0;
  double _containerWidth = 0;
  bool _needsScroll = false;
  String? _measuredText;
  TextStyle? _measuredStyle;
  bool _measurementScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this);
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) _controller.forward(from: 0);
        });
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _scheduleMeasurement(BuildContext context, double containerWidth) {
    final changed = _containerWidth != containerWidth ||
        _measuredText != widget.text ||
        _measuredStyle != widget.style;
    if (!changed || _measurementScheduled) return;
    _containerWidth = containerWidth;
    _measurementScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementScheduled = false;
      if (!mounted) return;
      _measure(context);
    });
  }

  void _measure(BuildContext context) {
    final span = TextSpan(text: widget.text, style: widget.style);
    final tp = TextPainter(
      text: span,
      textDirection: Directionality.of(context),
    )..layout();
    final textWidth = tp.width;
    final needsScroll = textWidth > _containerWidth;
    _measuredText = widget.text;
    _measuredStyle = widget.style;
    if (needsScroll && textWidth > 0 && _containerWidth > 0) {
      final distance = textWidth + 16;
      final duration = (distance / widget.scrollSpeed * 1000).round();
      _controller.duration = Duration(milliseconds: duration);
      _controller.forward(from: 0);
    } else {
      _controller.stop();
    }
    setState(() {
      _textWidth = textWidth;
      _needsScroll = needsScroll;
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _scheduleMeasurement(context, constraints.maxWidth);
        if (!_needsScroll) {
          return Text(
            widget.text,
            style: widget.style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
        }
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            child: Text(
              widget.text,
              style: widget.style,
              maxLines: 1,
              softWrap: false,
            ),
            builder: (context, child) {
              final offset = _controller.value * (_textWidth + 16);
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: child,
              );
            },
          ),
        );
      },
    );
  }
}
