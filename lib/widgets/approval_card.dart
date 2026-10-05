import 'package:flutter/material.dart';
import '../models/approval_request.dart';

class ApprovalCard extends StatelessWidget {
  final ApprovalRequest request;
  final Function(ApprovalRequest req, String outcome) onRespond;

  const ApprovalCard({
    super.key,
    required this.request,
    required this.onRespond,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 14.0, vertical: 8.0),
      decoration: BoxDecoration(
        color: const Color(0xFFFFFBEB),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFFDE68A),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFFEF3C7),
              borderRadius: BorderRadius.vertical(top: Radius.circular(11)),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.security_rounded,
                  color: Color(0xFFD97706),
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  '执行权限申请 (Tool Execution Approval)',
                  style: TextStyle(
                    color: Color(0xFFB45309),
                    fontWeight: FontWeight.bold,
                    fontSize: 13.5,
                  ),
                ),
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFFD97706),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    request.toolName,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                )
              ],
            ),
          ),

          // Body content
          Padding(
            padding: const EdgeInsets.all(14.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  request.reason.isNotEmpty ? request.reason : '智能体申请调用 ${request.toolName} 执行任务',
                  style: const TextStyle(
                    color: Color(0xFF1F2937),
                    fontWeight: FontWeight.w600,
                    fontSize: 13.5,
                  ),
                ),
                if (request.callId != null && request.callId!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    '调用编号: ${request.callId}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF6B7280),
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ],
            ),
          ),

          // Actions
          Padding(
            padding: const EdgeInsets.only(left: 14, right: 14, bottom: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: () => onRespond(request, 'rejected'),
                  icon: const Icon(Icons.close_rounded, size: 16, color: Color(0xFFDC2626)),
                  label: const Text('拒绝 (Reject)', style: TextStyle(color: Color(0xFFDC2626))),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Color(0xFFFCA5A5)),
                    backgroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: () => onRespond(request, 'allowed-once'),
                  icon: const Icon(Icons.check_rounded, size: 16, color: Colors.white),
                  label: const Text('允许一次 (Allow)', style: TextStyle(color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          )
        ],
      ),
    );
  }
}
