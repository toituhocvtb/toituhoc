import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart'; // Fix lỗi kIsWeb và Uint8List
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; // Thêm nén ảnh
import 'history_screen.dart'; // Khai báo file Lịch sử

class ApplicationScreen extends StatefulWidget {
  final String? initialCourse;
  const ApplicationScreen({super.key, this.initialCourse});

  @override
  State<ApplicationScreen> createState() => _ApplicationScreenState();
}

class _ApplicationScreenState extends State<ApplicationScreen> {
  // Trạng thái hệ thống
  bool _isLoadingRole = true;
  bool _isKNS = false;
  bool _isSubmitting = false;

  // Logic đồng hồ AI tâm lý học
  int _countdownSeconds = 15;
  int _dotIndex = 0;
  final List<String> _dotFrames = ['.', '..', '...', '..'];
  Timer? _submitTimer;

  // Logic bộ đếm từ trực tiếp
  int _learningsWordCount = 0;
  int _practicalWordCount = 0;

  // Controllers cho các ô nhập liệu
  final _learningsController = TextEditingController();
  final _practicalController = TextEditingController();
  final _driveLinkController = TextEditingController();

  // Dữ liệu cho Dropdown Khóa học
  List<String> _courseList = [];
  List<String> _allLearnedCourses = [];
  Set<String> _appliedCourses = {};
  bool _showAllCourses = false;
  String? _selectedCourse;

  // Trạng thái cho các Checkbox của Khối Nhân sự
  bool _isSharedGroup = false;
  bool _isCoffeeTalk = false;
  bool _isSpeaker = false;

  // Controllers mở rộng cho Khối Nhân sự (Coffee Talk)
  final _coffeeTalkNameController = TextEditingController();
  final _coffeeTalkLearningsController = TextEditingController();

  // Trạng thái lưu file minh chứng - Hỗ trợ nhiều file
  final List<Map<String, dynamic>> _appEvidenceAttachments = [];
  final List<Map<String, dynamic>> _groupShareAttachments = [];
  final List<Map<String, dynamic>> _speakerEvidenceAttachments = [];

  // Cấu hình số lượng ảnh linh hoạt từ Database
  int _maxAppTscImages = 1;
  int _maxAppKnsImages = 3;
  int _maxShareKnsImages = 2;
  int _maxSpeakerKnsImages = 3;

  // Cấu hình điểm linh hoạt
  int _knsMaxAi = 20;
  int _tscMaxAi = 10;
  int _shareGroupPts = 5;
  int _coffeeTalkPts = 2;
  int _speakerPts = 50;

  // Cờ check ẩn/hiện Form nhập liệu tự động
  bool _hasShareRule = false;
  bool _hasCoffeeRule = false;
  bool _hasSpeakerRule = false;

  @override
  void initState() {
    super.initState();
    if (widget.initialCourse != null) {
      _selectedCourse = widget.initialCourse;
    }
    _fetchUserRole();
    _fetchCourses();
    _fetchPointRules();

    // Lắng nghe thao tác gõ phím để cập nhật bộ đếm từ lập tức
    _learningsController.addListener(() {
      if (mounted) {
        setState(
          () => _learningsWordCount = _countWords(_learningsController.text),
        );
      }
    });
    _practicalController.addListener(() {
      if (mounted) {
        setState(
          () => _practicalWordCount = _countWords(_practicalController.text),
        );
      }
    });
  }

  // Tải cấu hình điểm & số lượng ảnh từ Database
  Future<void> _fetchPointRules() async {
    try {
      // 1. Tải số lượng ảnh
      final configRes = await Supabase.instance.client
          .from('system_configs')
          .select();
      if (mounted) {
        setState(() {
          for (var row in configRes) {
            if (row['config_value'] == null) continue;
            switch (row['config_key']) {
              case 'max_app_tsc_images':
                _maxAppTscImages = row['config_value'] as int;
                break;
              case 'max_app_kns_images':
                _maxAppKnsImages = row['config_value'] as int;
                break;
              case 'max_share_kns_images':
                _maxShareKnsImages = row['config_value'] as int;
                break;
              case 'max_speaker_kns_images':
                _maxSpeakerKnsImages = row['config_value'] as int;
                break;
            }
          }
        });
      }

      // 2. Tải điểm Gamification
      final res = await Supabase.instance.client
          .from('gamification_rules')
          .select();
      if (mounted) {
        setState(() {
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
                _hasShareRule = true;
                break;
              case 'coffee_talk':
                _coffeeTalkPts = row['points'] as int;
                _hasCoffeeRule = true;
                break;
              case 'speaker':
                _speakerPts = row['points'] as int;
                _hasSpeakerRule = true;
                break;
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải cấu hình điểm: $e');
    }
  }

  // Tích hợp AI chấm điểm (Ép trả JSON và Timeout 15s)
  Future<Map<String, dynamic>> _evaluateWithAI(
    String course,
    String learnings,
    String practical,
    int maxScore,
  ) async {
    try {
      const apiKey = String.fromEnvironment('GROQ_API_KEY');

      if (apiKey.isEmpty) {
        return {'score': 0, 'feedback': 'Lỗi thiếu cấu hình API Key.'};
      }

      final prompt =
          """
      Bạn là chuyên gia thẩm định đào tạo. Hãy chấm điểm mức độ 'Matching' giữa khóa học và nội dung ứng dụng thực tế.
      - Khóa học: $course
      - Kiến thức tâm đắc: $learnings
      - Thực tế áp dụng: $practical
      
      QUY ĐỊNH CHẤM ĐIỂM (RẤT QUAN TRỌNG):
      - Hệ thống đã nhận diện Khối của nhân sự này. THANG ĐIỂM TỐI ĐA áp dụng cho bài đánh giá này là: $maxScore điểm.
      - Bạn TUYỆT ĐỐI KHÔNG được chấm điểm số vượt quá $maxScore điểm trong bất kỳ trường hợp nào.
      
      Tiêu chí đánh giá:
      1. Độ liên quan: Nội dung áp dụng có thực sự xuất phát từ khóa học?
      2. Tính cụ thể: Hành động áp dụng có rõ ràng, chi tiết không?
      3. Tính thực tiễn: Kết quả mang lại có giá trị cho công việc không?

      YÊU CẦU BẮT BUỘC:
      - Trả về kết quả DƯỚI DẠNG JSON.
      - Cấu trúc JSON chuẩn xác: {"score": <số nguyên từ 0 đến $maxScore>, "feedback": "<Giải thích ngắn gọn 2-3 câu vì sao được điểm này. Nhận xét mang tính động viên>"}
      """;

      final url = Uri.parse('https://api.groq.com/openai/v1/chat/completions');

      // Chặn timeout sau 15 giây
      final response = await http
          .post(
            url,
            headers: {
              'Authorization': 'Bearer $apiKey',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              "model":
                  "llama-3.1-8b-instant", // Cập nhật sang model Llama 3.1 thế hệ mới nhất
              "response_format": {
                "type": "json_object",
              }, // Ép Groq trả JSON chuẩn
              "messages": [
                {"role": "user", "content": prompt},
              ],
              "temperature": 0.2, // Tăng nhẹ để feedback tự nhiên hơn
            }),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        // IN LỖI RA DEBUG CONSOLE ĐỂ BẮT BỆNH GROQ
        debugPrint('====== LỖI TỪ GROQ API ======');
        debugPrint('Mã trạng thái: ${response.statusCode}');
        debugPrint('Chi tiết lỗi: ${utf8.decode(response.bodyBytes)}');
        debugPrint('==============================');

        return {
          'score': (maxScore / 2).round(),
          'feedback': 'Hệ thống AI đang bận. Điểm tạm tính.',
        };
      }

      final responseData = jsonDecode(utf8.decode(response.bodyBytes));
      final aiText = responseData['choices'][0]['message']['content']
          .toString();

      final resultJson = jsonDecode(aiText);
      int score = resultJson['score'] ?? 0;
      String feedback = resultJson['feedback'] ?? 'Không có nhận xét.';

      return {
        'score': score > maxScore ? maxScore : score,
        'feedback': feedback,
      };
    } on TimeoutException {
      // Bắt lỗi quá thời gian 15 giây
      return {'score': -1, 'feedback': 'timeout'};
    } catch (e) {
      debugPrint('Lỗi AI: $e');
      return {'score': 0, 'feedback': 'Gặp sự cố khi kết nối AI.'};
    }
  }

  // Cập nhật danh sách khóa học hiển thị dựa trên checkbox
  void _updateCourseDropdown() {
    Set<String> displayCourses = Set.from(_allLearnedCourses);
    if (!_showAllCourses) {
      displayCourses.removeAll(_appliedCourses);
    }
    _courseList = displayCourses.toList();

    if (_selectedCourse != null && !_courseList.contains(_selectedCourse)) {
      _selectedCourse = null;
    }
  }

  // Lấy danh sách khóa học đã kê khai
  Future<void> _fetchCourses() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // 1. Lấy tất cả khóa học đã ghi nhận giờ học
      final hoursResponse = await Supabase.instance.client
          .from('learning_hours')
          .select('course_name')
          .eq('user_id', userId);

      // 2. Lấy tất cả khóa học ĐÃ kê khai ứng dụng
      final appsResponse = await Supabase.instance.client
          .from('practical_applications')
          .select('course_name')
          .eq('user_id', userId);

      if (mounted) {
        setState(() {
          _allLearnedCourses = (hoursResponse as List)
              .map((e) => e['course_name'] as String)
              .toList();

          _appliedCourses = (appsResponse as List)
              .map((e) => e['course_name'] as String)
              .toSet();

          _updateCourseDropdown();
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải danh sách khóa học: $e');
    }
  }

  // NGHIỆP VỤ 1: Tự động phân quyền (Đọc role từ Database)
  Future<void> _fetchUserRole() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      final data = await Supabase.instance.client
          .from('profiles')
          .select('role')
          .eq('id', userId)
          .single();

      if (mounted) {
        setState(() {
          _isKNS = (data['role'] == 'kns');
          _isLoadingRole = false;
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải role: $e');
      if (mounted) setState(() => _isLoadingRole = false);
    }
  }

  // Hàm đếm số lượng từ bằng Regex
  int _countWords(String text) {
    if (text.trim().isEmpty) return 0;
    return text.trim().split(RegExp(r'\s+')).length;
  }

  // Popup thông báo điểm AI và Nhận xét
  void _showAIScoreDialog(int score, int maxScore, String feedback) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kết quả đánh giá AI 🤖'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Điểm số: $score / $maxScore',
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Nhận xét từ AI:',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 4),
              Text(
                feedback,
                style: const TextStyle(
                  fontSize: 14,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đóng'),
          ),
        ],
      ),
    );
  }

  // Popup thông báo khi AI chấm quá lâu
  void _showTimeoutDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Hệ thống đang xử lý ⏳'),
        content: const Text(
          'Do lượng bài thi lớn, AI cần thêm thời gian để đọc và phân tích chi tiết bài ứng dụng của bạn.\n\n'
          'Hệ thống sẽ lưu lại và tiếp tục chấm điểm ngầm. Vui lòng kiểm tra lại điểm trong Lịch sử sau ít phút nhé!',
        ),
        actions: [
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Đã hiểu'),
          ),
        ],
      ),
    );
  }

  // NGHIỆP VỤ 2: Xử lý logic Gửi báo cáo
  Future<void> _submitApplication() async {
    final course = _selectedCourse ?? '';
    final learnings = _learningsController.text.trim();
    final practical = _practicalController.text.trim();
    final driveLink = _driveLinkController.text.trim();

    // 1. Kiểm tra khóa học (luôn bắt buộc)
    if (course.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Vui lòng chọn khóa học!')));
      return;
    }

    bool isMainAppFilled = learnings.isNotEmpty && practical.isNotEmpty;
    bool hasAnyKnsOption =
        _isKNS && (_isSharedGroup || _isCoffeeTalk || _isSpeaker);

    // Chặn lỗi bỏ trống linh hoạt (KNS có thể không cần form chính nếu có chọn option KNS)
    if (!_isKNS) {
      if (!isMainAppFilled) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vui lòng điền đầy đủ Kiến thức tâm đắc và Thực tế áp dụng!',
            ),
          ),
        );
        return;
      }
    } else {
      if (!isMainAppFilled && !hasAnyKnsOption) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vui lòng kê khai nội dung ứng dụng HOẶC chọn ít nhất 1 tiêu chí bổ sung!',
            ),
          ),
        );
        return;
      }
      if ((learnings.isNotEmpty && practical.isEmpty) ||
          (learnings.isEmpty && practical.isNotEmpty)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vui lòng điền ĐẦY ĐỦ cả Kiến thức tâm đắc và Thực tế áp dụng nếu bạn muốn kê khai hạng mục chính!',
            ),
          ),
        );
        return;
      }
    }

    // 2. NGHIỆP VỤ VALIDATE TỪ (Theo thiết kế mới: Cả 2 đều Min 50, No Max)
    if (isMainAppFilled) {
      if (_countWords(learnings) < 50) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nội dung tâm đắc PHẢI CÓ tối thiểu 50 từ!'),
          ),
        );
        return;
      }

      if (_countWords(practical) < 50) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Nội dung áp dụng thực tế PHẢI CÓ tối thiểu 50 từ!'),
          ),
        );
        return;
      }
    }

    // Validate Minh chứng cho KNS
    if (_isKNS) {
      if (isMainAppFilled &&
          _appEvidenceAttachments.isEmpty &&
          driveLink.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Khối Nhân sự bắt buộc phải đính kèm file hoặc link minh chứng cho phần ứng dụng!',
            ),
          ),
        );
        return;
      }
      if (_isSharedGroup && _groupShareAttachments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Vui lòng upload ít nhất 1 ảnh chụp màn hình chia sẻ Group!',
            ),
          ),
        );
        return;
      }
      if (_isSpeaker && _speakerEvidenceAttachments.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Vui lòng upload ít nhất 1 minh chứng làm diễn giả!'),
          ),
        );
        return;
      }
    }

    setState(() {
      _isSubmitting = true;
      _countdownSeconds = 15;
      _dotIndex = 0;
    });

    // Chạy đồng hồ đếm ngược và hiệu ứng dấu chấm nhấp nháy
    _submitTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_countdownSeconds > 0) _countdownSeconds--;
          _dotIndex = (_dotIndex + 1) % _dotFrames.length;
        });
      }
    });

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      final storage = Supabase.instance.client.storage.from(
        'learning-evidence',
      );

      // --- LOGIC UPLOAD FILE THẬT VÀO STORAGE ---
      String? appPathDB;
      String? groupPathDB;
      String? speakerPathDB;
      DateTime? shareTimestamp;

      // Hàm Helper ẩn để xử lý upload chung cho các loại ảnh
      Future<List<Map<String, dynamic>>> uploadListHelper(
        List<Map<String, dynamic>> list,
        String folder,
        String moduleType,
      ) async {
        List<Map<String, dynamic>> insertedList = [];
        for (int i = 0; i < list.length; i++) {
          final att = list[i];
          final fileExt = att['name'].toString().split('.').last;
          final fileName =
              '$folder/${userId}_${DateTime.now().millisecondsSinceEpoch}_$i.$fileExt';

          if (kIsWeb || att['bytes'] != null) {
            await storage.uploadBinary(fileName, att['bytes']);
          } else if (att['path'] != null) {
            await storage.upload(fileName, File(att['path']));
          }

          insertedList.add({
            'module_type': moduleType,
            'file_path': fileName,
            'file_name': att['name'],
            'file_size': att['size'],
          });
        }
        return insertedList;
      }

      List<Map<String, dynamic>> allAttachmentsToInsert = [];

      // 1. Upload minh chứng sản phẩm (KNS & TSC)
      if (_appEvidenceAttachments.isNotEmpty) {
        var res = await uploadListHelper(
          _appEvidenceAttachments,
          'apps',
          'app_evidence',
        );
        allAttachmentsToInsert.addAll(res);
        appPathDB =
            res.first['file_name']; // Lưu đại 1 tên để giữ tương thích bảng cũ
      }

      // 2. Upload ảnh share group (KNS)
      if (_isKNS && _groupShareAttachments.isNotEmpty) {
        var res = await uploadListHelper(
          _groupShareAttachments,
          'shares',
          'share_evidence',
        );
        allAttachmentsToInsert.addAll(res);
        groupPathDB = res.first['file_name'];
        shareTimestamp = DateTime.now();
      }

      // 3. Upload minh chứng diễn giả (KNS)
      if (_isKNS && _speakerEvidenceAttachments.isNotEmpty) {
        var res = await uploadListHelper(
          _speakerEvidenceAttachments,
          'speakers',
          'speaker_evidence',
        );
        allAttachmentsToInsert.addAll(res);
        speakerPathDB = res.first['file_name'];
      }

      // 3. Đóng gói dữ liệu cơ bản
      final Map<String, dynamic> payload = {
        'user_id': userId,
        'course_name': course,
        'key_learnings': learnings,
        'practical_results': practical,
        'drive_link': driveLink.isNotEmpty ? driveLink : null,
        'app_evidence_path': appPathDB, // Lưu đường dẫn thật vào DB
      };

      // Nếu là người của Khối Nhân Sự, đính kèm thêm dữ liệu Coffee Talk
      if (_isKNS) {
        payload.addAll({
          'is_shared_group': _isSharedGroup,
          'group_share_path': groupPathDB,
          'share_group_timestamp': shareTimestamp?.toIso8601String(),
          'coffee_talk_name': _isCoffeeTalk
              ? _coffeeTalkNameController.text.trim()
              : null,
          'coffee_talk_learnings': _isCoffeeTalk
              ? _coffeeTalkLearningsController.text.trim()
              : null,
          'is_speaker': _isSpeaker,
          'speaker_evidence_path': speakerPathDB,
        });
      }

      // 4. Gọi AI chấm điểm và tính tổng điểm Gamification (Module 3)
      int aiMaxScore = _isKNS ? _knsMaxAi : _tscMaxAi;
      Map<String, dynamic> aiResult = {
        'score': 0,
        'feedback': 'Chỉ kê khai tiêu chí bổ sung, không có bài học chính.',
      };
      bool isTimeout = false;

      if (isMainAppFilled) {
        aiResult = await _evaluateWithAI(
          course,
          learnings,
          practical,
          aiMaxScore,
        );
        isTimeout = aiResult['score'] == -1;
      }

      int aiScore = isTimeout ? 0 : aiResult['score'];

      payload['ai_score'] = isTimeout ? null : aiScore;
      payload['ai_feedback'] = isTimeout
          ? 'Đang chờ hệ thống chấm điểm ngầm...'
          : aiResult['feedback'];

      int totalGamificationPoints = aiScore; // Điểm sản phẩm ứng dụng

      if (_isKNS) {
        if (_isSharedGroup) {
          totalGamificationPoints +=
              _shareGroupPts; // Chia sẻ group chung linh hoạt
        }
        if (_isCoffeeTalk) {
          totalGamificationPoints +=
              _coffeeTalkPts; // Tham dự Coffee Talk linh hoạt
        }
        if (_isSpeaker) {
          totalGamificationPoints += _speakerPts; // Diễn giả linh hoạt
        }
      }

      payload['gamification_points'] = totalGamificationPoints;

      // 5. Bắn dữ liệu lên Supabase & Lấy ID
      final insertedRow = await Supabase.instance.client
          .from('practical_applications')
          .insert(payload)
          .select('id')
          .single();

      final recordId = insertedRow['id'];

      // 6. Gắn ID vào các ảnh và insert vào evidence_attachments
      if (allAttachmentsToInsert.isNotEmpty) {
        for (var att in allAttachmentsToInsert) {
          att['record_id'] = recordId;
        }
        await Supabase.instance.client
            .from('evidence_attachments')
            .insert(allAttachmentsToInsert);
      }

      _submitTimer?.cancel(); // Dừng đồng hồ

      // KIỂM TRA MOUNTED LẦN CUỐI CÙNG TRƯỚC KHI HIỂN THỊ UI
      if (mounted) {
        if (isMainAppFilled) {
          if (isTimeout) {
            _showTimeoutDialog();
          } else {
            _showAIScoreDialog(aiScore, aiMaxScore, aiResult['feedback']);
          }
        }

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('🎉 Gửi báo cáo thành công!'),
            backgroundColor: Colors.green,
          ),
        );

        // Reset Form sau khi gửi thành công
        _learningsController.clear();
        _practicalController.clear();
        _driveLinkController.clear();
        setState(() {
          _selectedCourse = null;
          _isSharedGroup = false;
          _isCoffeeTalk = false;
          _isSpeaker = false;
          _appEvidenceAttachments.clear();
          _groupShareAttachments.clear();
          _speakerEvidenceAttachments.clear();
        });
      }
    } catch (e) {
      _submitTimer?.cancel();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi Database: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSubmitting = false);
        _submitTimer?.cancel();
      }
    }
  }

  @override
  void dispose() {
    _submitTimer?.cancel();
    _learningsController.dispose();
    _practicalController.dispose();
    _driveLinkController.dispose();
    _coffeeTalkNameController.dispose();
    _coffeeTalkLearningsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Hiện vòng xoay trong lúc App đang chạy lên Supabase để hỏi xem user này là KNS hay TSC
    if (_isLoadingRole) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Kê khai kết quả ứng dụng'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: 'Xem lịch sử ứng dụng',
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const HistoryScreen(
                    initialIndex: 1,
                  ), // 1 là mở thẳng vào Tab SP Ứng dụng
                ),
              );
            },
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '1. Thông tin chung (Bắt buộc)',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                Checkbox(
                  value: _showAllCourses,
                  onChanged: (val) {
                    setState(() {
                      _showAllCourses = val ?? false;
                      _updateCourseDropdown();
                    });
                  },
                ),
                const Expanded(
                  child: Text(
                    'Cho phép kê khai lại các khóa đã nộp ứng dụng',
                    style: TextStyle(fontSize: 14),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<String>(
              // ignore: deprecated_member_use
              value: _selectedCourse,
              decoration: const InputDecoration(
                labelText: 'Chọn khóa học đã kê khai',
                border: OutlineInputBorder(),
              ),
              items: _courseList.map((String course) {
                return DropdownMenuItem<String>(
                  value: course,
                  child: Text(course),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  _selectedCourse = newValue;
                });
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _learningsController,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Kiến thức tâm đắc (Tối thiểu 50 từ)',
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Text(
                  _learningsWordCount < 50
                      ? 'Đã viết $_learningsWordCount từ (Cần thêm ${50 - _learningsWordCount} từ)'
                      : 'Đã viết $_learningsWordCount từ (Đạt yêu cầu)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _learningsWordCount < 50
                        ? Colors.red
                        : Colors.green.shade700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _practicalController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Thực tế áp dụng (Tối thiểu 50 từ)',
                border: OutlineInputBorder(),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 4),
                child: Text(
                  _practicalWordCount < 50
                      ? 'Đã viết $_practicalWordCount từ (Cần thêm ${50 - _practicalWordCount} từ)'
                      : 'Đã viết $_practicalWordCount từ (Đạt yêu cầu)',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: _practicalWordCount < 50
                        ? Colors.red
                        : Colors.green.shade700,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Đối với file Video hoặc file dung lượng lớn, vui lòng upload lên Google Drive cá nhân và dán link chia sẻ vào ô bên dưới.',
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _driveLinkController,
              decoration: const InputDecoration(
                labelText: 'Link Google Drive minh chứng (nếu có)',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            // Helper Widget để vẽ UI Upload đa năng
            _buildMultiUploadSection(
              title: 'Tải lên minh chứng ứng dụng',
              maxImages: _isKNS ? _maxAppKnsImages : _maxAppTscImages,
              attachmentsList: _appEvidenceAttachments,
              allowedExtensions: [
                'jpg',
                'jpeg',
                'png',
                'pdf',
                'doc',
                'docx',
                'xls',
                'xlsx',
              ],
            ),

            if (_isKNS &&
                _appEvidenceAttachments.isEmpty &&
                _driveLinkController.text.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 4.0),
                child: Text(
                  '* KNS bắt buộc phải có minh chứng (File hoặc Link Drive)',
                  style: TextStyle(color: Colors.red, fontSize: 12),
                ),
              ),
            const SizedBox(height: 24),

            // Tự động hiển thị thẻ này NẾU người đang đăng nhập là Khối Nhân Sự
            if (_isKNS) ...[
              const Text(
                '2. Tiêu chí bổ sung (Dành riêng Khối Nhân sự)',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),

              if (_hasShareRule) ...[
                SwitchListTile(
                  title: const Text('Đã chia sẻ kiến thức trong Group chung'),
                  value: _isSharedGroup,
                  onChanged: (val) => setState(() => _isSharedGroup = val),
                ),
                if (_isSharedGroup)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Vui lòng tải lên ảnh chụp màn hình chứng minh bạn đã chia sẻ bài học.',
                          style: TextStyle(
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildMultiUploadSection(
                          title: 'Tải lên ảnh chụp chia sẻ (Bắt buộc)',
                          maxImages: _maxShareKnsImages,
                          attachmentsList: _groupShareAttachments,
                          allowedExtensions: ['jpg', 'jpeg', 'png'],
                        ),
                      ],
                    ),
                  ),
              ],

              if (_hasCoffeeRule) ...[
                SwitchListTile(
                  title: const Text('Có tham dự chương trình Coffee Talk'),
                  value: _isCoffeeTalk,
                  onChanged: (val) => setState(() => _isCoffeeTalk = val),
                ),
                if (_isCoffeeTalk) ...[
                  Padding(
                    padding: const EdgeInsets.only(
                      left: 16.0,
                      right: 16.0,
                      bottom: 12.0,
                    ),
                    child: Column(
                      children: [
                        TextField(
                          controller: _coffeeTalkNameController,
                          decoration: const InputDecoration(
                            labelText: 'Tên chương trình Coffee Talk',
                            border: OutlineInputBorder(),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _coffeeTalkLearningsController,
                          maxLines: 2,
                          decoration: const InputDecoration(
                            labelText: 'Nội dung tâm đắc nhất',
                            border: OutlineInputBorder(),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],

              if (_hasSpeakerRule) ...[
                SwitchListTile(
                  title: const Text(
                    'Là Diễn giả / Người chia sẻ tại Coffee Talk',
                  ),
                  value: _isSpeaker,
                  onChanged: (val) => setState(() => _isSpeaker = val),
                ),
                if (_isSpeaker)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16.0,
                      vertical: 8.0,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '(Ví dụ: Thư mời làm diễn giả, slide nội dung đã thuyết trình, hoặc ảnh chụp đang chia sẻ)',
                          style: TextStyle(
                            fontSize: 13,
                            fontStyle: FontStyle.italic,
                            color: Colors.grey,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _buildMultiUploadSection(
                          title: 'Tải lên minh chứng diễn giả (Bắt buộc)',
                          maxImages: _maxSpeakerKnsImages,
                          attachmentsList: _speakerEvidenceAttachments,
                          allowedExtensions: [
                            'jpg',
                            'jpeg',
                            'png',
                            'pdf',
                            'doc',
                            'docx',
                            'ppt',
                            'pptx',
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
              const SizedBox(height: 24),
            ],

            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _isSubmitting ? null : _submitApplication,
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue[800],
                  foregroundColor: Colors.white,
                ),
                child: _isSubmitting
                    ? Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Text(
                            _countdownSeconds > 8
                                ? 'Đang chấm AI ${_dotFrames[_dotIndex]}'
                                : 'Đang chấm AI... (Còn ${_countdownSeconds}s)',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      )
                    : const Text(
                        'GỬI KẾT QUẢ',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Tách riêng logic xử lý file để bảo vệ Context
  Future<void> _handleFileSelection({
    required int maxImages,
    required List<Map<String, dynamic>> attachmentsList,
    required List<String> allowedExtensions,
  }) async {
    if (attachmentsList.length >= maxImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Bạn chỉ được tải lên tối đa $maxImages file!'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    FilePickerResult? result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: allowedExtensions,
      allowMultiple: true,
      withData: kIsWeb,
    );

    if (!mounted || result == null) return;

    if (attachmentsList.length + result.files.length > maxImages) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Chỉ được chọn thêm ${maxImages - attachmentsList.length} file!',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    List<Map<String, dynamic>> newAttachments = [];
    List<String> failedFiles = [];

    for (var file in result.files) {
      if (file.path == null && file.bytes == null) continue;

      String finalFileName = file.name;
      Uint8List? finalBytes = file.bytes;
      String? finalPath = file.path;
      int sizeInBytes = file.size;

      bool isImage = [
        'jpg',
        'jpeg',
        'png',
      ].contains(file.extension?.toLowerCase());

      try {
        if (isImage) {
          if (kIsWeb && finalBytes != null) {
            final compressedBytes = await FlutterImageCompress.compressWithList(
              finalBytes,
              minWidth: 1080,
              minHeight: 1080,
              quality: 70,
              format: CompressFormat.jpeg,
            );
            finalBytes = compressedBytes;
            sizeInBytes = compressedBytes.length;
            finalFileName = 'compressed_$finalFileName';
          } else if (!kIsWeb && finalPath != null) {
            final compressedFile = await FlutterImageCompress.compressAndGetFile(
              finalPath,
              '${finalPath}_compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
              quality: 70,
              minWidth: 1080,
              minHeight: 1080,
              format: CompressFormat.jpeg,
            );
            if (compressedFile != null) {
              finalPath = compressedFile.path;
              finalBytes = await compressedFile.readAsBytes();
              sizeInBytes = finalBytes.length;
              finalFileName = 'compressed_$finalFileName';
            }
          }
        }
      } catch (e) {
        debugPrint('Lỗi nén file: $e');
      }

      if (sizeInBytes <= 10485760) {
        newAttachments.add({
          'name': finalFileName,
          'path': finalPath,
          'bytes': finalBytes,
          'size': sizeInBytes,
        });
      } else {
        failedFiles.add(finalFileName);
      }
    }

    if (!mounted) return;

    Navigator.pop(context); // Đóng loading

    if (failedFiles.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Đã bỏ qua ${failedFiles.length} file vì dung lượng > 10MB sau nén.',
          ),
          backgroundColor: Colors.red,
        ),
      );
    }

    setState(() {
      attachmentsList.addAll(newAttachments);
    });
  }

  // Widget Helper chỉ lo việc vẽ UI
  Widget _buildMultiUploadSection({
    required String title,
    required int maxImages,
    required List<Map<String, dynamic>> attachmentsList,
    required List<String> allowedExtensions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: () => _handleFileSelection(
            maxImages: maxImages,
            attachmentsList: attachmentsList,
            allowedExtensions: allowedExtensions,
          ),
          icon: const Icon(Icons.upload_file),
          label: Text(
            attachmentsList.isNotEmpty
                ? 'Đã đính kèm ${attachmentsList.length}/$maxImages file'
                : '$title (Tối đa $maxImages file)',
          ),
        ),
        if (attachmentsList.isNotEmpty) ...[
          const SizedBox(height: 8),
          ...attachmentsList.map((att) {
            int index = attachmentsList.indexOf(att);
            return Container(
              margin: const EdgeInsets.only(bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                border: Border.all(color: Colors.grey.shade300),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.insert_drive_file,
                    color: Colors.blueGrey,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      att['name'],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.red, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () =>
                        setState(() => attachmentsList.removeAt(index)),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}
