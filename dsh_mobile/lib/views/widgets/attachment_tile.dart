import 'package:flutter/material.dart';

import '../../models/user_question.dart';

/// 会话内的图片附件（§4.1-3）。
///
/// 网关只转发**元数据**，字节留在宿主机 —— 所以这里必须带上 Authorization 头
/// 去拉，否则裸 `Image.network(url)` 会 401。这是最容易写错的一处：URL 看起来
/// 一切正常，图片却永远不出现。
///
/// 加载失败时显示 id 和尺寸而不是空白方块：空白方块无法区分「图还在加载」
/// 和「这张图取不到了」。
class AttachmentImageTile extends StatelessWidget {
  final AttachmentRef ref;
  final ({String url, Map<String, String> headers})? endpoint;
  final double maxWidth;

  const AttachmentImageTile({
    super.key,
    required this.ref,
    required this.endpoint,
    this.maxWidth = 240,
  });

  @override
  Widget build(BuildContext context) {
    final url = endpoint?.url;
    final headers = endpoint?.headers;

    final label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          ref.filename ?? ref.id,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Color(0xFF374151)),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          [
            ref.mimeType,
            if (ref.width != null) '${ref.width}×${ref.height}',
            if (ref.byteSize != null) '${(ref.byteSize! / 1024).toStringAsFixed(0)} KB',
          ].join('  ·  '),
          style: const TextStyle(fontSize: 10.5, color: Color(0xFF9CA3AF)),
        ),
      ],
    );

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (url == null)
            _placeholder(const Color(0xFFEF4444), '未连接网关，无法取回图片')
          else
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: 320),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(7),
                child: Image.network(
                  url,
                  headers: headers,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stack) =>
                      _placeholder(Colors.orange.shade700, '图片加载失败\n$error'),
                  loadingBuilder: (context, child, progress) {
                    if (progress == null) return child;
                    return SizedBox(
                      height: 120,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF0078D4)),
                            ),
                            const SizedBox(height: 7),
                            Text(
                              '正在加载图片…',
                              style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          const SizedBox(height: 7),
          label,
        ],
      ),
    );
  }

  Widget _placeholder(Color color, String text) {
    return Container(
      width: double.infinity,
      height: 96,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withOpacity(0.06),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: color.withOpacity(0.25)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: color, height: 1.4),
      ),
    );
  }
}

/// 提问提交失败的提示条。与卡片分开，因为它描述的是**传输**问题而不是问题本身 ——
/// 卡片还要留着让用户重试。
class QuestionErrorBanner extends StatelessWidget {
  final String message;

  const QuestionErrorBanner({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFFEF2F2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFFECACA)),
      ),
      child: Row(
        children: [
          const Icon(Icons.error_outline_rounded, size: 15, color: Color(0xFFB91C1C)),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(fontSize: 11.5, color: Color(0xFFB91C1C), height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}