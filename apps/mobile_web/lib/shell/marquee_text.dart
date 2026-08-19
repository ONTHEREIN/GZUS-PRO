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

  void _measure() {
    final span = TextSpan(text: widget.text, style: widget.style);
    final tp = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    _textWidth = tp.width;
    if (_needsScroll && _textWidth > 0 && _containerWidth > 0) {
      final distance = _textWidth + 16;
      final duration = (distance / widget.scrollSpeed * 1000).round();
      _controller.duration = Duration(milliseconds: duration);
      _controller.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _containerWidth = constraints.maxWidth;
        return ClipRect(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final span = TextSpan(text: widget.text, style: widget.style);
              final tp =
                  TextPainter(text: span, textDirection: TextDirection.ltr)
                    ..layout();
              _textWidth = tp.width;
              _needsScroll = _textWidth > _containerWidth;
              if (!_needsScroll) {
                _controller.stop();
                return Text(widget.text,
                    style: widget.style,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis);
              }
              if (!_controller.isAnimating &&
                  _controller.status == AnimationStatus.dismissed) {
                WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
              }
              final offset = _controller.value * (_textWidth + 16);
              return Transform.translate(
                offset: Offset(-offset, 0),
                child: Text(widget.text,
                    style: widget.style, maxLines: 1, softWrap: false),
              );
            },
          ),
        );
      },
    );
  }
}
