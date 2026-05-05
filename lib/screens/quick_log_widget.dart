import 'dart:io';
import 'package:flutter/foundation.dart'; // Thêm kIsWeb và Uint8List
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // Thêm thư viện format số
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart'; // Thư viện nén ảnh chuyên dụng
import 'application_screen.dart';

class QuickLogWidget extends StatefulWidget {
  final VoidCallback onSavedSuccess;

  const QuickLogWidget({super.key, required this.onSavedSuccess});

  @override
  State<QuickLogWidget> createState() => _QuickLogWidgetState();
}

class _QuickLogWidgetState extends State<QuickLogWidget> {
  final _courseController = TextEditingController();
  final _hoursController = TextEditingController(); // Thêm controller Giờ
  final _minutesController = TextEditingController(); // Thêm controller Phút
  int _totalCalculatedMinutes = 0; // Biến lưu tổng số phút hiển thị realtime

  List<String> _platforms = [];
  String? _selectedPlatform;
  final _otherPlatformController = TextEditingController();
  bool _isSaving = false;
  bool _isLoadingData = true;

  String _userRole = 'tsc';
  List<Map<String, dynamic>> _phaseDataList =
      []; // Lưu trữ thêm ngày bắt đầu/kết thúc
  List<String> _phaseList = [];
  String? _selectedPhase;
  final DateTime _completionDate =
      DateTime.now(); // Ngày giờ hoàn thành (có thể sửa)
  // Trạng thái lưu file minh chứng (KNS) - Hỗ trợ nhiều file
  final List<Map<String, dynamic>> _selectedAttachments = [];
  int _maxKnsImages = 1; // Mặc định 1, sẽ được cập nhật từ Admin Config
  @override
  void initState() {
    super.initState();
    _fetchInitialData();
    // Lắng nghe sự thay đổi ở 2 ô nhập để tính lại tổng phút realtime
    _hoursController.addListener(_calculateTotalMinutes);
    _minutesController.addListener(_calculateTotalMinutes);
  }

  void _calculateTotalMinutes() {
    int h = int.tryParse(_hoursController.text) ?? 0;
    int m = int.tryParse(_minutesController.text) ?? 0;
    setState(() {
      _totalCalculatedMinutes = (h * 60) + m;
    });
  }

  @override
  void dispose() {
    _courseController.dispose();
    _hoursController.dispose();
    _minutesController.dispose();
    _otherPlatformController.dispose();
    super.dispose();
  }

  // Lấy đồng thời Platform và Role/Phase từ Database
  Future<void> _fetchInitialData() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;

      // 1. Lấy role của user để phân loại Chặng/Đợt
      String role = 'tsc';
      bool isAllRole = false;
      if (userId != null) {
        final profileRes = await Supabase.instance.client
            .from('profiles')
            .select('role')
            .eq('id', userId)
            .maybeSingle();
        if (profileRes != null && profileRes['role'] != null) {
          role = profileRes['role'];
          if (role == 'all') {
            isAllRole = true;
            role =
                'kns'; // Mượn quyền KNS để lấy nền tảng khóa học + validate ảnh
          }
        }
      }

      // 2. Lấy danh sách nền tảng (Lọc tự động theo Role của user)
      final platformRes = await Supabase.instance.client
          .from('learning_platforms')
          .select('name')
          .or('target_role.eq.all, target_role.eq.$role');

      // Tải cấu hình số lượng ảnh tối đa cho QuickLog từ bảng system_configs
      final configRes = await Supabase.instance.client
          .from('system_configs')
          .select('config_value')
          .eq('config_key', 'max_quicklog_kns_images')
          .maybeSingle();

      // Tải kèm start_date, end_date, và claim_cutoff_date để xử lý logic ẩn/hiện chặng
      var periodQuery = Supabase.instance.client
          .from('learning_periods')
          .select('period_name, start_date, end_date, claim_cutoff_date')
          .eq('is_active', true);

      if (isAllRole) {
        periodQuery = periodQuery.inFilter('target_role', ['tsc', 'kns']);
      } else {
        periodQuery = periodQuery.eq('target_role', role);
      }
      final periodsRes = await periodQuery.order('start_date', ascending: true);

      if (mounted) {
        setState(() {
          _platforms = (platformRes as List)
              .map((e) => e['name'] as String)
              .toList();
          if (_platforms.isEmpty) {
            _platforms = ['Udemy', 'LMS', 'Coursera', 'Khác'];
          }
          if (_platforms.contains('Udemy')) {
            _selectedPlatform = 'Udemy';
          } else {
            _selectedPlatform = _platforms.first;
          }

          _userRole = role;
          if (configRes != null && configRes['config_value'] != null) {
            _maxKnsImages =
                int.tryParse(configRes['config_value'].toString()) ?? 1;
          }

          // Tự động format tên chặng kèm thời gian thực tế từ DB cho Dropdown
          _phaseDataList = [];
          final now = DateTime.now();

          for (var p in List<Map<String, dynamic>>.from(periodsRes)) {
            Map<String, dynamic> period = Map<String, dynamic>.from(p);
            String rawName = period['period_name'] ?? '';
            String baseName = rawName
                .replaceAll(RegExp(r'\s*\(.*?\)'), '')
                .trim();

            DateTime? sDate = DateTime.tryParse(period['start_date'] ?? '');
            DateTime? eDate = DateTime.tryParse(period['end_date'] ?? '');

            DateTime? cutoffDate = DateTime.tryParse(
              period['claim_cutoff_date'] ?? '',
            );
            cutoffDate ??= eDate;

            // Bỏ qua (ẩn) các chặng ĐÃ QUA NGÀY CHẶN KÊ KHAI (Cut-off date)
            // Ghi chú: Không ẩn chặng chưa bắt đầu vì Admin đã chủ động mở sớm bằng is_active = TRUE
            if (cutoffDate != null &&
                now.isAfter(cutoffDate.add(const Duration(days: 1)))) {
              continue;
            }

            if (sDate != null && eDate != null) {
              period['period_name'] =
                  '$baseName (${sDate.day}/${sDate.month} - ${eDate.day}/${eDate.month})';
            } else {
              period['period_name'] = baseName;
            }
            _phaseDataList.add(period);
          }

          // [UI/UX] XỬ LÝ RIÊNG CHO ROLE ALL: Gộp hiển thị để không bắt User phải chọn 1 trong 2
          if (isAllRole && _phaseDataList.length > 1) {
            String combinedName = _phaseDataList
                .map((e) => e['period_name'].toString().split(' (').first)
                .join(' & ');
            String combinedDates = 'Tích lũy kép';
            _phaseList = ['$combinedName ($combinedDates)'];

            // Ghi đè list nội bộ để validation khoảng thời gian (từ Start sớm nhất đến End muộn nhất) pass thành công
            DateTime? firstStart = DateTime.tryParse(
              _phaseDataList.first['start_date'] ?? '',
            );
            DateTime? lastEnd = DateTime.tryParse(
              _phaseDataList.last['end_date'] ?? '',
            );
            _phaseDataList = [
              {
                'period_name': _phaseList.first,
                'start_date': firstStart?.toIso8601String(),
                'end_date': lastEnd?.toIso8601String(),
              },
            ];
          } else {
            _phaseList = _phaseDataList
                .map((e) => e['period_name'] as String)
                .toList();
          }

          if (_phaseList.isEmpty) {
            _phaseList = ['Đợt hiện tại'];
            _selectedPhase = _phaseList.first;
          } else {
            // Logic tự động nhận diện chặng theo ngày hiện tại
            final now = DateTime.now();
            String? autoSelect;

            // Ưu tiên 1: Tìm chặng đang diễn ra (Hôm nay nằm giữa start và end)
            for (var p in _phaseDataList) {
              final s = DateTime.tryParse(p['start_date'] ?? '');
              final e = DateTime.tryParse(p['end_date'] ?? '');
              if (s != null && e != null) {
                if (now.isAfter(s.subtract(const Duration(days: 1))) &&
                    now.isBefore(e.add(const Duration(days: 1)))) {
                  autoSelect = p['period_name'];
                  break;
                }
              }
            }

            // Ưu tiên 2: Nếu chưa đến thời gian chặng nào (VD: Đang là 26/4 nhưng chặng 1 là 5/5), tìm chặng tương lai gần nhất
            if (autoSelect == null) {
              for (var p in _phaseDataList) {
                final s = DateTime.tryParse(p['start_date'] ?? '');
                if (s != null && now.isBefore(s)) {
                  autoSelect = p['period_name'];
                  break;
                }
              }
            }

            // Ưu tiên 3: Nếu đã qua hết tất cả các chặng, chốt chặng cuối cùng
            _selectedPhase = autoSelect ?? _phaseList.last;
          }
          _isLoadingData = false;
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải dữ liệu ban đầu: $e');
      if (mounted) setState(() => _isLoadingData = false);
    }
  }

  // Hàm tự động gợi ý Chặng phù hợp dựa trên ngày hoàn thành người dùng chọn
  String? _suggestPhaseForDate(DateTime date) {
    for (var p in _phaseDataList) {
      final s = DateTime.tryParse(p['start_date'] ?? '');
      final e = DateTime.tryParse(p['end_date'] ?? '');
      if (s != null && e != null) {
        if (date.isAfter(s.subtract(const Duration(days: 1))) &&
            date.isBefore(e.add(const Duration(days: 1)))) {
          return p['period_name'];
        }
      }
    }
    return null;
  }

  // Hiển thị gợi ý chuyển sang form Kê khai ứng dụng
  void _showApplicationPrompt(String savedCourse) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kê khai thành công'),
        content: const Text(
          'Bạn có muốn tiếp tục kê khai kết quả ứng dụng thực tế cho khóa học này không?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Để sau', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx); // Đóng Dialog
              // Chuyển sang màn hình Kê khai ứng dụng và truyền tên khóa học
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) =>
                      ApplicationScreen(initialCourse: savedCourse),
                ),
              );
            },
            child: const Text('Kê khai ngay'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveLearningHours() async {
    final course = _courseController.text.trim();

    final finalPlatform = _selectedPlatform == 'Khác'
        ? _otherPlatformController.text.trim()
        : _selectedPlatform;

    if (course.isEmpty ||
        _totalCalculatedMinutes <= 0 ||
        finalPlatform == null ||
        finalPlatform.isEmpty ||
        _selectedPhase == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Vui lòng điền đủ thông tin, thời gian học và chọn đợt/chặng!',
          ),
        ),
      );
      return;
    }

    if (_userRole == 'kns' && _selectedAttachments.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Khối Nhân sự bắt buộc phải đính kèm ít nhất 1 ảnh minh chứng!',
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // --- KIỂM TRA MÔ THUẪN GIỮA "NGÀY HOÀN THÀNH" VÀ "CHẶNG" ---
    final selectedPhaseConfig = _phaseDataList.firstWhere(
      (p) => p['period_name'] == _selectedPhase,
      orElse: () => {},
    );

    if (selectedPhaseConfig.isNotEmpty) {
      final sDate = DateTime.tryParse(selectedPhaseConfig['start_date'] ?? '');
      final eDate = DateTime.tryParse(selectedPhaseConfig['end_date'] ?? '');

      if (sDate != null && eDate != null) {
        bool isDateInPhase =
            _completionDate.isAfter(sDate.subtract(const Duration(days: 1))) &&
            _completionDate.isBefore(eDate.add(const Duration(days: 1)));

        if (!isDateInPhase) {
          // Ngày hoàn thành nằm ngoài Chặng đã chọn -> Chặn lại và gợi ý
          String? suggestedPhase = _suggestPhaseForDate(_completionDate);

          if (!mounted) return;
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.event_busy, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Sai lệch thời gian'),
                ],
              ),
              content: Text(
                'Ngày hoàn thành bạn chọn (${_completionDate.day}/${_completionDate.month}/${_completionDate.year}) KHÔNG NẰM TRONG thời gian của ${_selectedPhase!.split(' (').first}.\n\n'
                '${suggestedPhase != null ? '💡 Gợi ý: Với ngày hoàn thành này, bạn nên chọn chặng "$suggestedPhase".' : 'Vui lòng kiểm tra lại Ngày hoàn thành hoặc chọn lại Chặng phù hợp để đảm bảo điểm số được tính chính xác.'}',
                style: const TextStyle(height: 1.5),
              ),
              actions: [
                if (suggestedPhase != null)
                  TextButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      setState(() {
                        _selectedPhase = suggestedPhase;
                      });
                    },
                    child: const Text(
                      'Tự động đổi Chặng',
                      style: TextStyle(
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                  ),
                  child: const Text('Tôi sẽ sửa lại ngày'),
                ),
              ],
            ),
          );
          return; // Dừng việc lưu vào DB
        }
      }
    }
    // -------------------------------------------------------------

    setState(() => _isSaving = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;

      // Bóc tách tên chặng gốc (loại bỏ phần ngày tháng trong ngoặc) để lưu chuẩn vào DB
      String dbPhaseBatch = _selectedPhase ?? '';
      if (dbPhaseBatch.contains(' (')) {
        dbPhaseBatch = dbPhaseBatch
            .substring(0, dbPhaseBatch.indexOf(' ('))
            .trim();
      }

      // 1. Insert giờ học trước để lấy ID (Dùng .select().single() để lấy dòng vừa tạo)
      final insertedRow = await Supabase.instance.client
          .from('learning_hours')
          .insert({
            'user_id': user?.id,
            'course_name': course,
            'duration_minutes': _totalCalculatedMinutes,
            'phase_batch':
                dbPhaseBatch, // Đã lưu chuẩn tên (Ví dụ: Chặng 1 thay vì Chặng 1 (1/5 - 30/6))
            'platform': finalPlatform,
            'completion_date': _completionDate.toIso8601String(),
            'evidence_file_name': _selectedAttachments.isNotEmpty
                ? _selectedAttachments.first['name']
                : null,
          })
          .select('id')
          .single();

      final recordId = insertedRow['id'];

      // 2. Upload Multi-file & Insert vào evidence_attachments
      if (_userRole == 'kns' && _selectedAttachments.isNotEmpty) {
        List<Map<String, dynamic>> attachmentInserts = [];

        for (int i = 0; i < _selectedAttachments.length; i++) {
          final att = _selectedAttachments[i];
          final fileExt = att['name'].toString().split('.').last;
          final fileName =
              '${user?.id}_quicklog_${DateTime.now().millisecondsSinceEpoch}_$i.$fileExt';
          final storagePath = 'kns_evidence/$fileName';

          if (kIsWeb || att['bytes'] != null) {
            await Supabase.instance.client.storage
                .from('learning-evidence')
                .uploadBinary(storagePath, att['bytes']);
          } else if (att['path'] != null) {
            final file = File(att['path']);
            await Supabase.instance.client.storage
                .from('learning-evidence')
                .upload(storagePath, file);
          }

          attachmentInserts.add({
            'record_id': recordId,
            'module_type': 'quick_log',
            'file_path': storagePath,
            'file_name': att['name'],
            'file_size': att['size'],
          });
        }

        if (attachmentInserts.isNotEmpty) {
          await Supabase.instance.client
              .from('evidence_attachments')
              .insert(attachmentInserts);
        }
      }

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('🎉 Lưu giờ học thành công!'),
          backgroundColor: Colors.green,
        ),
      );

      final currentCourse = course; // Lưu tạm trước khi clear
      _courseController.clear();
      _hoursController.clear();
      _minutesController.clear();
      setState(() {
        _totalCalculatedMinutes = 0;
        _selectedAttachments.clear();
      });
      widget.onSavedSuccess();

      // Gợi ý chuyển sang màn hình kê khai ứng dụng
      _showApplicationPrompt(currentCourse);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Lỗi: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Kê khai nhanh giờ học',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _courseController,
              minLines: 1, // Tên khóa tự động giãn nhiều dòng nếu dài
              maxLines: 4,
              keyboardType: TextInputType.multiline,
              decoration: InputDecoration(
                labelText: 'Tên khóa học',
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _isLoadingData
                ? const Center(child: LinearProgressIndicator())
                : Column(
                    children: [
                      // Gộp Chặng và Nền tảng lên cùng 1 hàng ngang
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            flex: 5,
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _selectedPhase,
                              decoration: InputDecoration(
                                labelText: 'Chặng/Đợt kê khai',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical:
                                      14, // Tăng từ 8 lên 14 để mở rộng chiều cao form
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              items: _phaseList.map((String phase) {
                                // Tự động ngắt dòng trước dấu "(" để tách tên chặng và thời gian
                                String displayText = phase.replaceFirst(
                                  ' (',
                                  '\n(',
                                );
                                return DropdownMenuItem<String>(
                                  value: phase,
                                  child: Text(
                                    displayText,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize:
                                          11, // Cỡ chữ nhỏ lại để vừa khít 2 dòng
                                      height: 1.2,
                                    ),
                                  ),
                                );
                              }).toList(),
                              onChanged: (String? newValue) {
                                setState(() => _selectedPhase = newValue);
                              },
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            flex: 4,
                            child: DropdownButtonFormField<String>(
                              isExpanded: true,
                              initialValue: _selectedPlatform,
                              decoration: InputDecoration(
                                labelText: 'Nền tảng',
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical:
                                      14, // Tăng từ 8 lên 14 để cao bằng ô bên trái
                                ),
                                border: OutlineInputBorder(
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              items: _platforms.map((String platform) {
                                return DropdownMenuItem<String>(
                                  value: platform,
                                  child: Text(
                                    platform,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                );
                              }).toList(),
                              onChanged: (String? newValue) {
                                setState(() => _selectedPlatform = newValue);
                              },
                            ),
                          ),
                        ],
                      ),
                      // Hiển thị gợi ý UI/UX cho Role ALL
                      if (_userRole == 'kns' &&
                          _phaseList.isNotEmpty &&
                          _phaseList.first.contains('Tích lũy kép')) ...[
                        const Padding(
                          padding: EdgeInsets.only(top: 8.0, bottom: 4.0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                color: Colors.blue,
                                size: 16,
                              ),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Đặc quyền: Thành tích của bạn sẽ được tự động ghi nhận đồng thời cho cả 2 bảng xếp hạng (TSC & KNS).',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blue,
                                    fontStyle: FontStyle.italic,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                      if (_selectedPlatform == 'Khác') ...[
                        const SizedBox(height: 12),
                        TextField(
                          controller: _otherPlatformController,
                          decoration: InputDecoration(
                            labelText: 'Nhập tên nền tảng khác',
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      // UI Tối ưu diện tích: Gom "Thời gian học" và "Upload minh chứng" lên cùng 1 hàng
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Cột 1: Thời gian học (Số giờ/phút) và Hệ thống ghi nhận
                          Expanded(
                            flex: 4,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    const Text(
                                      'Số giờ đã học',
                                      style: TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.black87,
                                      ),
                                    ),
                                    if (_totalCalculatedMinutes > 0) ...[
                                      const SizedBox(width: 6),
                                      Text(
                                        '(Quy đổi: $_totalCalculatedMinutes phút)',
                                        style: const TextStyle(
                                          color: Colors.green,
                                          fontWeight: FontWeight.bold,
                                          fontSize: 12,
                                          fontStyle: FontStyle.italic,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: _hoursController,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter
                                              .digitsOnly,
                                        ],
                                        decoration: InputDecoration(
                                          labelText: 'Giờ',
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 8,
                                              ),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: TextField(
                                        controller: _minutesController,
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter
                                              .digitsOnly,
                                        ],
                                        decoration: InputDecoration(
                                          labelText: 'Phút',
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 8,
                                              ),
                                          border: OutlineInputBorder(
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          if (_userRole == 'kns') ...[
                            const SizedBox(width: 12),
                            // Cột 2: Nâng cấp UI Upload minh chứng (KNS) chuẩn App xịn
                            Expanded(
                              flex: 5,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Tải lên minh chứng',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: Colors.black87,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  InkWell(
                                    onTap: () async {
                                      if (_selectedAttachments.length >=
                                          _maxKnsImages) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          SnackBar(
                                            content: Text(
                                              'Bạn chỉ được tải lên tối đa $_maxKnsImages ảnh minh chứng!',
                                            ),
                                            backgroundColor: Colors.red,
                                          ),
                                        );
                                        return;
                                      }

                                      FilePickerResult? result =
                                          await FilePicker.pickFiles(
                                            type: FileType.custom,
                                            allowedExtensions: [
                                              'jpg',
                                              'jpeg',
                                              'png',
                                            ],
                                            allowMultiple: true,
                                            withData: kIsWeb,
                                          );
                                      if (!context.mounted) return;

                                      if (result != null) {
                                        if (_selectedAttachments.length +
                                                result.files.length >
                                            _maxKnsImages) {
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                'Số lượng vượt quá giới hạn. Chỉ được chọn thêm ${_maxKnsImages - _selectedAttachments.length} ảnh!',
                                              ),
                                              backgroundColor: Colors.red,
                                            ),
                                          );
                                          return;
                                        }

                                        showDialog(
                                          context: context,
                                          barrierDismissible: false,
                                          builder: (BuildContext context) {
                                            return const Center(
                                              child:
                                                  CircularProgressIndicator(),
                                            );
                                          },
                                        );

                                        List<Map<String, dynamic>>
                                        newAttachments = [];

                                        for (var file in result.files) {
                                          if (file.path == null &&
                                              file.bytes == null) {
                                            continue;
                                          }

                                          String finalFileName = file.name;
                                          Uint8List? finalBytes = file.bytes;
                                          String? finalPath = file.path;
                                          int sizeInBytes = file.size;

                                          try {
                                            if (kIsWeb && finalBytes != null) {
                                              var compressedBytes =
                                                  await FlutterImageCompress.compressWithList(
                                                    finalBytes,
                                                    minWidth: 1080,
                                                    minHeight: 1080,
                                                    quality: 70,
                                                    format: CompressFormat.jpeg,
                                                  );
                                              finalBytes = compressedBytes;
                                              sizeInBytes =
                                                  compressedBytes.length;
                                              finalFileName =
                                                  'compressed_$finalFileName';
                                            } else if (!kIsWeb &&
                                                finalPath != null) {
                                              var compressedFile =
                                                  await FlutterImageCompress.compressAndGetFile(
                                                    finalPath,
                                                    '${finalPath}_compressed_${DateTime.now().millisecondsSinceEpoch}.jpg',
                                                    quality: 70,
                                                    minWidth: 1080,
                                                    minHeight: 1080,
                                                    format: CompressFormat.jpeg,
                                                  );
                                              if (compressedFile != null) {
                                                finalPath = compressedFile.path;
                                                finalBytes =
                                                    await compressedFile
                                                        .readAsBytes();
                                                sizeInBytes = finalBytes.length;
                                                finalFileName =
                                                    'compressed_$finalFileName';
                                              }
                                            }
                                          } catch (e) {
                                            debugPrint('Lỗi nén ảnh: $e');
                                          }

                                          if (sizeInBytes <= 5242880) {
                                            newAttachments.add({
                                              'name': finalFileName,
                                              'path': finalPath,
                                              'bytes': finalBytes,
                                              'size': sizeInBytes,
                                            });
                                          } else {
                                            if (context.mounted) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                SnackBar(
                                                  content: Text(
                                                    'Ảnh $finalFileName sau nén vẫn > 5MB, đã bị bỏ qua!',
                                                  ),
                                                  backgroundColor: Colors.red,
                                                ),
                                              );
                                            }
                                          }
                                        }

                                        if (context.mounted) {
                                          Navigator.pop(context);
                                        }

                                        setState(() {
                                          _selectedAttachments.addAll(
                                            newAttachments,
                                          );
                                        });
                                      }
                                    },
                                    borderRadius: BorderRadius.circular(8),
                                    child: Container(
                                      height:
                                          48, // Ép chiều cao bằng với TextField bên trái để cân đối
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      decoration: BoxDecoration(
                                        color: _selectedAttachments.isNotEmpty
                                            ? Colors.green.shade50
                                            : Colors.grey.shade50,
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: _selectedAttachments.isNotEmpty
                                              ? Colors.green.shade400
                                              : Colors.grey.shade400,
                                          style: BorderStyle.solid,
                                          width: 1,
                                        ),
                                      ),
                                      child: Row(
                                        children: [
                                          Icon(
                                            _selectedAttachments.isNotEmpty
                                                ? Icons.check_circle
                                                : Icons.cloud_upload_outlined,
                                            color:
                                                _selectedAttachments.isNotEmpty
                                                ? Colors.green
                                                : Colors.blue.shade700,
                                            size: 20,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Column(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _selectedAttachments
                                                          .isNotEmpty
                                                      ? '${_selectedAttachments.length}/$_maxKnsImages ảnh'
                                                      : 'Tải lên minh chứng',
                                                  style: TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 12,
                                                    color:
                                                        _selectedAttachments
                                                            .isNotEmpty
                                                        ? Colors.green.shade800
                                                        : Colors.black87,
                                                  ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                                const Text(
                                                  'JPG, PNG (<5MB)',
                                                  style: TextStyle(
                                                    fontSize: 10,
                                                    color: Colors.grey,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ] else ...[
                            const SizedBox(width: 12),
                            const Spacer(
                              flex: 5,
                            ), // Spacer giả lập để giữ khung "Số giờ" không bị kéo dãn to bè khi không có box upload
                          ],
                        ],
                      ),

                      // Render danh sách ảnh đã chọn ngay bên dưới hàng
                      if (_userRole == 'kns' &&
                          _selectedAttachments.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        ..._selectedAttachments.map((att) {
                          int index = _selectedAttachments.indexOf(att);
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              border: Border.all(color: Colors.grey.shade300),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.image,
                                  color: Colors.blue,
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    att['name'],
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.close,
                                    color: Colors.red,
                                    size: 20,
                                  ),
                                  padding: EdgeInsets.zero,
                                  constraints: const BoxConstraints(),
                                  onPressed: () {
                                    setState(() {
                                      _selectedAttachments.removeAt(index);
                                    });
                                  },
                                ),
                              ],
                            ),
                          );
                        }),
                      ],
                    ],
                  ),
            const SizedBox(height: 16),
            // Nút Lưu mở rộng toàn màn hình
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveLearningHours,
                icon: _isSaving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.flash_on, size: 18),
                label: Text(
                  _isSaving ? 'Đang lưu...' : 'Ghi nhận giờ học',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0054A6),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
