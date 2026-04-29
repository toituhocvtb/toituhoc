import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class HistoryScreen extends StatefulWidget {
  final int initialIndex; // 0: Giờ học, 1: Ứng dụng
  const HistoryScreen({super.key, required this.initialIndex});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<dynamic> _learningHistory = [];
  List<dynamic> _appHistory = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchHistoryData();
  }

  Future<void> _fetchHistoryData() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // Lấy lịch sử giờ học
      final hoursRes = await Supabase.instance.client
          .from('learning_hours')
          .select('course_name, duration_minutes, platform, created_at')
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      // Lấy lịch sử ứng dụng (Bổ sung lấy thêm nội dung và feedback của AI)
      final appsRes = await Supabase.instance.client
          .from('practical_applications')
          .select(
            'course_name, gamification_points, created_at, key_learnings, practical_results, ai_feedback',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false);

      if (mounted) {
        setState(() {
          _learningHistory = hoursRes;
          _appHistory = appsRes;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải lịch sử: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  String _formatDate(String isoString) {
    try {
      final date = DateTime.parse(isoString).toLocal();
      return '${date.day}/${date.month}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return '';
    }
  }

  // Hiển thị Popup chi tiết bài ứng dụng kèm Nhận xét AI
  void _showAppDetailsDialog(Map<String, dynamic> item) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          item['course_name'] ?? 'Chi tiết bài ứng dụng',
          style: const TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 16,
            color: Color(0xFF0054A6),
          ),
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildDetailRow('Kiến thức tâm đắc:', item['key_learnings']),
              const SizedBox(height: 12),
              _buildDetailRow('Thực tế áp dụng:', item['practical_results']),
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0),
                child: Divider(height: 1, thickness: 1),
              ),
              Row(
                children: [
                  const Icon(Icons.stars, color: Colors.orange, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    'Điểm đạt được: ${item['gamification_points'] ?? 0} điểm',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: Colors.orange,
                      fontSize: 15,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Khung Feedback của AI
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.blue.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.smart_toy,
                          color: Colors.blue.shade700,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          'AI Nhận xét & Góp ý:',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.blue.shade800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      (item['ai_feedback'] != null &&
                              item['ai_feedback'].toString().trim().isNotEmpty)
                          ? item['ai_feedback']
                          : 'Hệ thống đang xử lý chấm điểm ngầm. Bạn vui lòng quay lại sau ít phút nhé.',
                      style: TextStyle(
                        fontStyle: FontStyle.italic,
                        fontSize: 13,
                        color: Colors.blue.shade900,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, dynamic value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value?.toString() ?? 'Không có dữ liệu',
          style: const TextStyle(color: Colors.black54, fontSize: 13),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      initialIndex: widget.initialIndex,
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Lịch sử chi tiết'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Giờ học đã khai'),
              Tab(text: 'SP Ứng dụng'),
            ],
          ),
        ),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(
                children: [
                  // Tab 1: Lịch sử giờ học
                  _learningHistory.isEmpty
                      ? const Center(child: Text('Chưa có dữ liệu giờ học'))
                      : ListView.builder(
                          itemCount: _learningHistory.length,
                          itemBuilder: (context, index) {
                            final item = _learningHistory[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              child: ListTile(
                                leading: const CircleAvatar(
                                  backgroundColor: Colors.green,
                                  child: Icon(Icons.timer, color: Colors.white),
                                ),
                                title: Text(
                                  item['course_name'] ?? '',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                subtitle: Text(
                                  '${item['platform']} • ${_formatDate(item['created_at'])}',
                                ),
                                trailing: Text(
                                  '+${item['duration_minutes']}p',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: Colors.green,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                  // Tab 2: Lịch sử ứng dụng
                  _appHistory.isEmpty
                      ? const Center(child: Text('Chưa có dữ liệu ứng dụng'))
                      : ListView.builder(
                          itemCount: _appHistory.length,
                          itemBuilder: (context, index) {
                            final item = _appHistory[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 8,
                              ),
                              // Gắn InkWell để tạo hiệu ứng bấm và gọi hàm hiện Popup
                              child: InkWell(
                                borderRadius: BorderRadius.circular(12),
                                onTap: () => _showAppDetailsDialog(item),
                                child: ListTile(
                                  leading: const CircleAvatar(
                                    backgroundColor: Colors.orange,
                                    child: Icon(
                                      Icons.star,
                                      color: Colors.white,
                                    ),
                                  ),
                                  title: Text(
                                    item['course_name'] ?? '',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  subtitle: Text(
                                    _formatDate(item['created_at']),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        '+${item['gamification_points'] ?? 0}đ',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                          color: Colors.orange,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      const Icon(
                                        Icons.chevron_right,
                                        color: Colors.grey,
                                      ), // Mũi tên gợi ý bấm
                                    ],
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ],
              ),
      ),
    );
  }
}
