import 'dart:convert';
import 'dart:async';
import 'package:http/http.dart' as http;
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

  // Bẫy: Lưu số lần thử lại để tránh Spam API
  final Map<int, int> _retryAttempts = {};

  // Cấu hình điểm cơ bản để tính toán lại tổng điểm
  int _knsMaxAi = 20;
  int _tscMaxAi = 10;
  int _shareGroupPts = 5;
  int _coffeeTalkPts = 2;
  int _speakerPts = 50;
  bool _isKNS = false;

  @override
  void initState() {
    super.initState();
    _fetchSystemConfigs();
    _fetchHistoryData();
  }

  Future<void> _fetchSystemConfigs() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        final profile = await Supabase.instance.client
            .from('profiles')
            .select('role')
            .eq('id', userId)
            .single();
        if (mounted) setState(() => _isKNS = profile['role'] == 'kns');
      }

      final res = await Supabase.instance.client
          .from('gamification_rules')
          .select();
      for (var row in res) {
        switch (row['rule_key']) {
          case 'kns_max_ai':
            _knsMaxAi = row['points'] as int;
            break;
          case 'tsc_max_ai':
            _tscMaxAi = row['points'] as int;
            break;
          case 'share_group':
            _shareGroupPts = row['points'] as int;
            break;
          case 'coffee_talk':
            _coffeeTalkPts = row['points'] as int;
            break;
          case 'speaker':
            _speakerPts = row['points'] as int;
            break;
        }
      }
    } catch (e) {
      debugPrint('Lỗi tải config: $e');
    }
  }

  Future<void> _retryAIGrading(Map<String, dynamic> item) async {
    final int recordId = item['id'];

    // Bẫy: Kiểm tra số lần thử
    int attempts = _retryAttempts[recordId] ?? 0;
    if (attempts >= 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Đã thử lại quá 2 lần nhưng hệ thống AI vẫn bận. Vui lòng quay lại sau!',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _retryAttempts[recordId] = attempts + 1;
      _isLoading = true;
    });

    try {
      int maxScore = _isKNS ? _knsMaxAi : _tscMaxAi;
      const apiKey = String.fromEnvironment('GROQ_API_KEY');
      if (apiKey.isEmpty) throw Exception('Thiếu API Key');

      final prompt =
          '''
      Bạn là chuyên gia thẩm định đào tạo. Hãy chấm điểm mức độ 'Matching' giữa khóa học và nội dung ứng dụng thực tế.
      - Khóa học: ${item['course_name']}
      - Kiến thức tâm đắc: ${item['key_learnings']}
      - Thực tế áp dụng: ${item['practical_results']}
      
      QUY ĐỊNH CHẤM ĐIỂM:
      - THANG ĐIỂM TỐI ĐA: $maxScore điểm.
      - Không chấm vượt quá $maxScore điểm.
      - Trả về kết quả DƯỚI DẠNG JSON: {"score": <số>, "feedback": "<Nhận xét>"}
      ''';

      final response = await http
          .post(
            Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              "model": "llama-3.1-8b-instant",
              "response_format": {"type": "json_object"},
              "messages": [
                {"role": "user", "content": prompt},
              ],
              "temperature": 0.2,
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) throw Exception('Lỗi API');

      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      final resultJson = jsonDecode(
        responseData['choices'][0]['message']['content'].toString(),
      );

      int aiScore = resultJson['score'] ?? 0;
      if (aiScore > maxScore) aiScore = maxScore;
      String feedback = resultJson['feedback'] ?? 'Không có nhận xét.';

      // Tính lại tổng điểm
      int totalPoints = aiScore;
      if (item['is_shared_group'] == true) totalPoints += _shareGroupPts;
      if (item['is_coffee_talk'] == true) totalPoints += _coffeeTalkPts;
      if (item['is_speaker'] == true) totalPoints += _speakerPts;

      // Cập nhật Database
      await Supabase.instance.client
          .from('practical_applications')
          .update({
            'ai_score': aiScore,
            'ai_feedback': feedback,
            'ai_grade_status': 'SUCCESS',
            'gamification_points': totalPoints,
          })
          .eq('id', recordId);

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Chấm điểm lại thành công!'),
          backgroundColor: Colors.green,
        ),
      );

      _fetchHistoryData(); // Tải lại danh sách
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Lỗi khi chấm lại: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
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

      // Lấy lịch sử ứng dụng (Bổ sung lấy id, status và các trường để phục vụ chấm lại)
      final appsRes = await Supabase.instance.client
          .from('practical_applications')
          .select(
            'id, course_name, gamification_points, created_at, key_learnings, practical_results, ai_feedback, ai_grade_status, ai_score, is_shared_group, is_coffee_talk, is_speaker',
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
                  color:
                      (item['ai_grade_status'] == 'ERROR' ||
                          item['ai_grade_status'] == 'TIMEOUT')
                      ? Colors.orange.shade50
                      : Colors.blue.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color:
                        (item['ai_grade_status'] == 'ERROR' ||
                            item['ai_grade_status'] == 'TIMEOUT')
                        ? Colors.orange.shade300
                        : Colors.blue.shade200,
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          (item['ai_grade_status'] == 'ERROR' ||
                                  item['ai_grade_status'] == 'TIMEOUT')
                              ? Icons.warning_amber_rounded
                              : Icons.smart_toy,
                          color:
                              (item['ai_grade_status'] == 'ERROR' ||
                                  item['ai_grade_status'] == 'TIMEOUT')
                              ? Colors.orange.shade800
                              : Colors.blue.shade700,
                          size: 18,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            (item['ai_grade_status'] == 'ERROR' ||
                                    item['ai_grade_status'] == 'TIMEOUT')
                                ? 'AI gặp sự cố (Điểm tạm tính)'
                                : 'AI Nhận xét & Góp ý:',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color:
                                  (item['ai_grade_status'] == 'ERROR' ||
                                      item['ai_grade_status'] == 'TIMEOUT')
                                  ? Colors.orange.shade900
                                  : Colors.blue.shade800,
                            ),
                          ),
                        ),
                        if (item['ai_grade_status'] == 'ERROR' ||
                            item['ai_grade_status'] == 'TIMEOUT')
                          ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 0,
                              ),
                              minimumSize: const Size(60, 26),
                            ),
                            onPressed: () {
                              Navigator.pop(ctx);
                              _retryAIGrading(item);
                            },
                            child: const Text(
                              'Chấm lại',
                              style: TextStyle(fontSize: 12),
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
                        color:
                            (item['ai_grade_status'] == 'ERROR' ||
                                item['ai_grade_status'] == 'TIMEOUT')
                            ? Colors.orange.shade900
                            : Colors.blue.shade900,
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
