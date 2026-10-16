import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// GenUI 的 `chart` 组件：bars / line / donut。
///
/// 为什么自绘而不是引图表库：这一层只需要三种基本图形，而规范里 `chart` 的语义
/// 很明确（≤8 点时用它、更重交互的用 `echart`）。为一个轻量组件引入依赖会让 APK
/// 变大，也会让"跟随宿主主题"这件事需要额外适配。自绘的代价只有几十行 painter。
///
/// 不做的（明确降级，不是遗漏）：tooltip、缩放、交互图例。规范里这些属于 `echart`
/// 的能力，而 `echart` 在手机端本轮不渲染（见 genui_view.dart 的支持清单）。
class GenuiChart extends StatelessWidget {
  const GenuiChart({
    super.key,
    required this.kind,
    required this.data,
    this.series = const [],
    this.horizontal = false,
    this.stacked = false,
    this.palette = const [],
    this.height = 220,
  });

  final String kind;
  final List<GenuiPoint> data;
  final List<GenuiSeries> series;
  final bool horizontal;
  final bool stacked;
  final List<Color> palette;
  final double height;

  @override
  Widget build(BuildContext context) {
    final colors = palette.isEmpty ? defaultChartPalette(context) : palette;
    if (kind == 'donut') {
      return _DonutChart(data: data, palette: colors, height: height);
    }
    return SizedBox(
      height: height,
      child: CustomPaint(
        painter: _AxisChartPainter(
          kind: kind,
          data: data,
          series: series,
          horizontal: horizontal,
          stacked: stacked,
          palette: colors,
          // 文字与网格走宿主主题 token：App 的颜色都在 ThemeScope 里，
          // Material 的 colorScheme 在深色模式下与它并不一致。
          textStyle: TextStyle(fontSize: 10, color: context.c.textTertiary),
          gridColor: context.c.border,
        ),
        size: Size.infinite,
      ),
    );
  }
}

/// 默认分类色板：从主题强调色按色相旋转生成，而不是自带一套硬编码色。
List<Color> defaultChartPalette(BuildContext context) {
  final hsl = HSLColor.fromColor(context.c.accent);
  return <Color>[
    context.c.accent,
    hsl.withHue((hsl.hue + 40) % 360).toColor(),
    hsl.withHue((hsl.hue + 90) % 360).toColor(),
    context.c.success,
    hsl.withHue((hsl.hue + 240) % 360).toColor(),
    context.c.warning,
  ];
}

class GenuiPoint {
  const GenuiPoint(this.label, this.value, [this.color]);
  final String label;
  final double value;
  final Color? color;

  /// 解析一个 `{label, value, color?}` 或裸数字。
  static GenuiPoint? fromJson(Object? raw, int index) {
    if (raw is num) return GenuiPoint('$index', raw.toDouble());
    if (raw is Map) {
      final label = raw['label']?.toString() ?? '$index';
      final value = _toDouble(raw['value']);
      if (value == null) return null;
      final c = raw['color'];
      return GenuiPoint(label, value, c is String ? _parseHex(c) : null);
    }
    return null;
  }
}

class GenuiSeries {
  const GenuiSeries(this.label, this.points);
  final String label;
  final List<GenuiPoint> points;

  static GenuiSeries? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final label = raw['label']?.toString() ?? '';
    final rawData = raw['data'];
    final points = <GenuiPoint>[];
    if (rawData is List) {
      for (var i = 0; i < rawData.length; i++) {
        final p = GenuiPoint.fromJson(rawData[i], i);
        if (p != null) points.add(p);
      }
    }
    return GenuiSeries(label, points);
  }
}

double? _toDouble(Object? v) {
  if (v is num) return v.toDouble();
  if (v is String) return double.tryParse(v);
  return null;
}

Color? _parseHex(String s) {
  var hex = s.trim();
  if (hex.startsWith('#')) hex = hex.substring(1);
  if (hex.length == 6) hex = 'FF$hex';
  if (hex.length != 8) return null;
  final v = int.tryParse(hex, radix: 16);
  return v == null ? null : Color(v);
}

/// 「好看」的轴上限：取 1/2/5 × 10^n 中第一个不小于 max 的值。
double niceCeil(double max) {
  if (max <= 0) return 1;
  final exp = (math.log(max) / math.ln10).floor();
  final base = math.pow(10, exp).toDouble();
  for (final m in const [1.0, 2.0, 5.0, 10.0]) {
    if (max <= m * base) return m * base;
  }
  return 10 * base;
}

class _AxisChartPainter extends CustomPainter {
  _AxisChartPainter({
    required this.kind,
    required this.data,
    required this.series,
    required this.horizontal,
    required this.stacked,
    required this.palette,
    required this.textStyle,
    required this.gridColor,
  });

  final String kind;
  final List<GenuiPoint> data;
  final List<GenuiSeries> series;
  final bool horizontal;
  final bool stacked;
  final List<Color> palette;
  final TextStyle textStyle;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 分类与取值：多序列时分类以第一条序列的标签为准（规范如此）。
    final cats = <String>[];
    final rows = <List<double>>[];
    if (series.isNotEmpty) {
      final first = series.first.points;
      for (final p in first) {
        cats.add(p.label);
      }
      for (final s in series) {
        rows.add([for (final p in s.points) p.value]);
      }
      if (cats.isEmpty) return;
    } else {
      for (final p in data) {
        cats.add(p.label);
      }
      rows.add([for (final p in data) p.value]);
      if (cats.isEmpty) return;
    }

    // 轴范围
    double maxV = 0;
    double minV = 0;
    for (final r in rows) {
      for (final v in r) {
        maxV = math.max(maxV, v);
        minV = math.min(minV, v);
      }
    }
    if (stacked) {
      maxV = 0;
      for (var c = 0; c < cats.length; c++) {
        var sum = 0.0;
        for (final r in rows) {
          if (c < r.length) sum += math.max(0, r[c]);
        }
        maxV = math.max(maxV, sum);
      }
      minV = 0;
    }
    maxV = niceCeil(maxV == 0 ? 1 : maxV);

    const labelW = 34.0;
    const labelH = 16.0;
    final plotLeft = horizontal ? labelW + 24 : labelW;
    final plotRect = Rect.fromLTRB(
      plotLeft,
      6,
      size.width - 6,
      size.height - labelH - 4,
    );
    if (plotRect.width <= 8 || plotRect.height <= 8) return;

    // 网格 + Y 轴刻度（4 段）
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final t = i / 4;
      final v = maxV * t;
      final y = horizontal ? plotRect.bottom - t * plotRect.height : plotRect.bottom - t * plotRect.height;
      canvas.drawLine(Offset(plotRect.left, y), Offset(plotRect.right, y), gridPaint);
      if (!horizontal) {
        _text(canvas, _fmt(v), Offset(4, y - 6));
      }
    }

    final n = cats.length;
    final slot = (horizontal ? plotRect.height : plotRect.width) / n;

    if (kind == 'line') {
      for (var s = 0; s < rows.length; s++) {
        final color = palette[s % palette.length];
        final paint = Paint()
          ..color = color
          ..strokeWidth = 2
          ..style = PaintingStyle.stroke;
        final path = Path();
        for (var c = 0; c < rows[s].length && c < n; c++) {
          final v = rows[s][c];
          final x = plotRect.left + slot * (c + 0.5);
          final y = plotRect.bottom - (v / maxV) * plotRect.height;
          if (c == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        canvas.drawPath(path, paint);
        // 点
        final dot = Paint()..color = color;
        for (var c = 0; c < rows[s].length && c < n; c++) {
          final v = rows[s][c];
          final x = plotRect.left + slot * (c + 0.5);
          final y = plotRect.bottom - (v / maxV) * plotRect.height;
          canvas.drawCircle(Offset(x, y), 2.6, dot);
        }
      }
    } else {
      // bars：分组或堆叠
      final groupCount = stacked ? 1 : rows.length;
      final groupW = slot * 0.72;
      final barW = groupW / groupCount;
      for (var c = 0; c < n; c++) {
        var stackTop = 0.0;
        for (var s = 0; s < rows.length; s++) {
          if (c >= rows[s].length) continue;
          final v = rows[s][c];
          if (v <= 0 && !stacked) continue;
          final color = stacked
              ? palette[s % palette.length]
              : (data.isNotEmpty && c < data.length && data[c].color != null
                  ? data[c].color!
                  : palette[s % palette.length]);
          final paint = Paint()..color = color;
          if (horizontal) {
            final h = barW;
            final y = plotRect.top + slot * c + (stacked ? (slot - groupW) / 2 : (slot - groupW) / 2 + s * barW);
            final w = (v / maxV) * plotRect.width;
            final baseX = plotRect.left + (stacked ? stackTop : 0);
            canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(baseX, y, math.max(1, w), h * 0.9), const Radius.circular(3)),
              paint,
            );
            if (stacked) stackTop += w;
          } else {
            final w = barW;
            final x = plotRect.left + slot * c + (slot - groupW) / 2 + (stacked ? 0 : s * barW);
            final h = (v / maxV) * plotRect.height;
            final baseY = stacked ? plotRect.bottom - stackTop : plotRect.bottom;
            canvas.drawRRect(
              RRect.fromRectAndRadius(Rect.fromLTWH(x, baseY - h, w * 0.9, math.max(1, h)), const Radius.circular(3)),
              paint,
            );
            if (stacked) stackTop += h;
          }
        }
      }
    }

    // 分类标签：太密就抽稀（每 k 个画一个）
    final step = n > 10 ? (n / 8).ceil() : 1;
    for (var c = 0; c < n; c += step) {
      final t = cats[c];
      if (horizontal) {
        _text(canvas, _ellipsis(t, 8), Offset(4, plotRect.top + slot * (c + 0.5) - 6));
      } else {
        final x = plotRect.left + slot * (c + 0.5);
        final painter = _layout(_ellipsis(t, 7));
        painter.paint(canvas, Offset(x - painter.width / 2, plotRect.bottom + 3));
      }
    }
  }

  TextPainter _layout(String s) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
    return tp;
  }

  void _text(Canvas canvas, String s, Offset at) => _layout(s).paint(canvas, at);

  String _ellipsis(String s, int max) => s.length <= max ? s : '${s.substring(0, max - 1)}…';

  String _fmt(double v) {
    if (v == v.roundToDouble()) {
      final n = v.toInt();
      if (n.abs() >= 10000) return '${(n / 10000).toStringAsFixed(1)}万';
      return '$n';
    }
    return v.toStringAsFixed(1);
  }

  @override
  bool shouldRepaint(covariant _AxisChartPainter old) =>
      old.kind != kind || old.stacked != stacked || old.horizontal != horizontal || old.series != series || old.data != data;
}

/// 环形图：占比。图例带数值与百分比（规范里 donut 的图例口径）。
class _DonutChart extends StatelessWidget {
  const _DonutChart({required this.data, required this.palette, required this.height});

  final List<GenuiPoint> data;
  final List<Color> palette;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();
    final total = data.fold<double>(0, (a, p) => a + math.max(0, p.value));
    final onSurface = context.c.textTertiary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          height: height,
          width: height,
          child: CustomPaint(
            painter: _DonutPainter(
              values: [for (final p in data) math.max(0, p.value)],
              colors: [for (var i = 0; i < data.length; i++) data[i].color ?? palette[i % palette.length]],
              holeColor: context.c.surface,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (var i = 0; i < data.length; i++)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          color: data[i].color ?? palette[i % palette.length],
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          data[i].label,
                          style: TextStyle(fontSize: 11.5, color: onSurface),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        total <= 0
                            ? _trim(data[i].value)
                            : '${_trim(data[i].value)} · ${(data[i].value / total * 100).toStringAsFixed(0)}%',
                        style: TextStyle(fontSize: 11, color: onSurface),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  static String _trim(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
}

class _DonutPainter extends CustomPainter {
  _DonutPainter({required this.values, required this.colors, required this.holeColor});

  final List<double> values;
  final List<Color> colors;
  final Color holeColor;

  @override
  void paint(Canvas canvas, Size size) {
    final total = values.fold<double>(0, (a, b) => a + b);
    if (total <= 0) return;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height).deflate(4);
    var start = -math.pi / 2;
    for (var i = 0; i < values.length; i++) {
      final sweep = values[i] / total * 2 * math.pi;
      final paint = Paint()
        ..color = colors[i % colors.length]
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(10, size.width * 0.16);
      canvas.drawArc(rect, start, sweep - 0.02, false, paint);
      start += sweep;
    }
    // 中心挖空（画一个背景色圆，避免依赖 BlendMode）
    canvas.drawCircle(rect.center, rect.width / 2 - math.max(10, size.width * 0.16) / 1.6, Paint()..color = holeColor);
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) => old.values != values || old.colors != colors;
}
