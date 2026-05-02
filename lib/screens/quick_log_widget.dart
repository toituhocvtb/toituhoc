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
  bool _isLatePhase = false; // Cờ kiểm tra kê khai muộn
  bool _confirmLate = false; // Checkbox xác nhận kê khai muộn
  DateTime _completionDate = DateTime.now(); // Ngày giờ hoàn thành (có thể sửa)
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

      // 1. Lấy danh sách nền tảng
      final platformRes = await Supabase.instance.client
          .from('learning_platforms')
          .select('name');

      // 2. Lấy role của user để phân loại Chặng/Đợt
      String role = 'tsc';
      if (userId != null) {
        final profileRes = await Supabase.instance.client
            .from('profiles')
            .select('role')
            .eq('id', userId)
            .maybeSingle();
        if (profileRes != null && profileRes['role'] != null) {
          role = profileRes['role'];
        }
      }

      // Tải cấu hình số lượng ảnh tối đa cho QuickLog từ bảng system_configs
      final configRes = await Supabase.instance.client
          .from('system_configs')
          .select('config_value')
          .eq('config_key', 'max_quicklog_kns_images')
          .maybeSingle();

      // Tải kèm start_date và end_date để xử lý logic cảnh báo
      final periodsRes = await Supabase.instance.client
          .from('learning_periods')
          .select('period_name, start_date, end_date')
          .eq('target_role', role)
          .order('start_date', ascending: true);

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
            _maxKnsImages = configRes['config_value'] as int;
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

            // Bỏ qua (ẩn) các chặng chưa đến thời gian bắt đầu
            if (sDate != null && now.isBefore(sDate)) {
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
          _phaseList = _phaseDataList
              .map((e) => e['period_name'] as String)
              .toList();

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
            _checkLatePhase(_selectedPhase);
          }
          _isLoadingData = false;
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải dữ liệu ban đầu: $e');
      if (mounted) setState(() => _isLoadingData = false);
    }
  }

  // Hàm kiểm tra xem chặng được chọn đã quá hạn so với thực tế chưa
  void _checkLatePhase(String? phaseName) {
    if (phaseName == null) return;
    final phase = _phaseDataList.firstWhere(
      (p) => p['period_name'] == phaseName,
      orElse: () => {},
    );
    if (phase.isNotEmpty) {
      final endDate = DateTime.tryParse(phase['end_date'] ?? '');
      // Nếu chọn chặng cũ mà hôm nay đã qua hạn kết thúc
      if (endDate != null &&
          DateTime.now().isAfter(endDate.add(const Duration(days: 1)))) {
        setState(() {
          _isLatePhase = true;
          _confirmLate = false; // Bắt người dùng phải tích xác nhận lại
        });
        return;
      }
    }
    setState(() {
      _isLatePhase = false;
      _confirmLate = false;
    });
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
                        _checkLatePhase(_selectedPhase);
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
                                  vertical: 8,
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
                                _checkLatePhase(newValue); // Gọi check muộn
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
                                  vertical: 8,
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
                      // UI Tối ưu diện tích: Gom "Thời gian hoàn thành" và "Thời gian học" lên 1 hàng ngang
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Cột 1: Thời gian hoàn thành
                          Expanded(
                            flex: 5,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Thời gian hoàn thành',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      child: InkWell(
                                        onTap: () async {
                                          final now = DateTime.now();
                                          final initDate =
                                              _completionDate.isAfter(now)
                                              ? now
                                              : _completionDate;
                                          final pickedDate =
                                              await showDatePicker(
                                                context: context,
                                                initialDate: initDate,
                                                firstDate: DateTime(2020),
                                                lastDate: now,
                                                locale: const Locale(
                                                  'vi',
                                                  'VN',
                                                ), // Ép hiển thị lịch Tiếng Việt
                                              );
                                          if (pickedDate != null && mounted) {
                                            setState(() {
                                              _completionDate = DateTime(
                                                pickedDate.year,
                                                pickedDate.month,
                                                pickedDate.day,
                                                _completionDate.hour,
                                                _completionDate.minute,
                                              );
                                            });
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.grey.shade400,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              '${_completionDate.day}/${_completionDate.month}/${_completionDate.year}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    Expanded(
                                      child: InkWell(
                                        onTap: () async {
                                          final pickedTime = await showTimePicker(
                                            context: context,
                                            initialTime: TimeOfDay.fromDateTime(
                                              _completionDate,
                                            ),
                                            builder: (context, child) =>
                                                MediaQuery(
                                                  data: MediaQuery.of(context)
                                                      .copyWith(
                                                        alwaysUse24HourFormat:
                                                            true,
                                                      ),
                                                  child: child!,
                                                ),
                                          );
                                          if (pickedTime != null &&
                                              context.mounted) {
                                            final now = DateTime.now();
                                            final newDateTime = DateTime(
                                              _completionDate.year,
                                              _completionDate.month,
                                              _completionDate.day,
                                              pickedTime.hour,
                                              pickedTime.minute,
                                            );
                                            if (newDateTime.isAfter(now)) {
                                              ScaffoldMessenger.of(
                                                context,
                                              ).showSnackBar(
                                                const SnackBar(
                                                  content: Text(
                                                    'Không thể chọn giờ ở tương lai!',
                                                  ),
                                                  backgroundColor: Colors.red,
                                                ),
                                              );
                                              return;
                                            }
                                            setState(
                                              () =>
                                                  _completionDate = newDateTime,
                                            );
                                          }
                                        },
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 4,
                                            vertical: 12,
                                          ),
                                          decoration: BoxDecoration(
                                            border: Border.all(
                                              color: Colors.grey.shade400,
                                            ),
                                            borderRadius: BorderRadius.circular(
                                              8,
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              '${_completionDate.hour.toString().padLeft(2, '0')}:${_completionDate.minute.toString().padLeft(2, '0')}',
                                              style: const TextStyle(
                                                fontSize: 12,
                                                fontWeight: FontWeight.w600,
                                              ),
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
                          const SizedBox(width: 12),
                          // Cột 2: Thời gian học (Số giờ/phút)
                          Expanded(
                            flex: 4,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Số giờ đã học',
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.black87,
                                  ),
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
                                    const SizedBox(width: 4),
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
                        ],
                      ),

                      // Chuyển dòng hiển thị phút ra khỏi Container để không làm hỏng bố cục
                      if (_totalCalculatedMinutes > 0)
                        Padding(
                          padding: const EdgeInsets.only(top: 12.0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Text(
                              'Hệ thống ghi nhận: $_totalCalculatedMinutes phút',
                              style: const TextStyle(
                                color: Colors.green,
                                fontWeight: FontWeight.bold,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
            const SizedBox(height: 16),

            // Nâng cấp UI Upload minh chứng (KNS) chuẩn App xịn
            if (_userRole == 'kns') ...[
              InkWell(
                onTap: () async {
                  if (_selectedAttachments.length >= _maxKnsImages) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Bạn chỉ được tải lên tối đa $_maxKnsImages ảnh minh chứng!',
                        ),
                        backgroundColor: Colors.red,
                      ),
                    );
                    return;
                  }

                  FilePickerResult? result = await FilePicker.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: ['jpg', 'jpeg', 'png'],
                    allowMultiple: true, // Bật tính năng chọn nhiều file
                    withData: kIsWeb,
                  );
                  if (!context.mounted) return;

                  if (result != null) {
                    if (_selectedAttachments.length + result.files.length >
                        _maxKnsImages) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            'Số lượng vượt quá giới hạn. Chỉ được chọn thêm ${_maxKnsImages - _selectedAttachments.length} ảnh!',
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }

                    // Hiện popup loading trong lúc xử lý nén nhiều file
                    showDialog(
                      context: context,
                      barrierDismissible: false,
                      builder: (BuildContext context) {
                        return const Center(child: CircularProgressIndicator());
                      },
                    );

                    List<Map<String, dynamic>> newAttachments = [];

                    for (var file in result.files) {
                      if (file.path == null && file.bytes == null) continue;

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
                          sizeInBytes = compressedBytes.length;
                          finalFileName = 'compressed_$finalFileName';
                        } else if (!kIsWeb && finalPath != null) {
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
                            finalBytes = await compressedFile.readAsBytes();
                            sizeInBytes = finalBytes.length;
                            finalFileName = 'compressed_$finalFileName';
                          }
                        }
                      } catch (e) {
                        debugPrint('Lỗi nén ảnh: $e');
                      }

                      if (sizeInBytes <= 5242880) {
                        // Giới hạn 5MB sau khi nén
                        newAttachments.add({
                          'name': finalFileName,
                          'path': finalPath,
                          'bytes': finalBytes,
                          'size': sizeInBytes,
                        });
                      } else {
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
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

                    if (context.mounted) Navigator.pop(context); // Tắt loading

                    setState(() {
                      _selectedAttachments.addAll(newAttachments);
                    });
                  }
                },
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    vertical: 14,
                    horizontal: 16,
                  ),
                  decoration: BoxDecoration(
                    color: _selectedAttachments.isNotEmpty
                        ? Colors.green.shade50
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _selectedAttachments.isNotEmpty
                          ? Colors.green.shade400
                          : Colors.grey.shade300,
                      style: BorderStyle.solid,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _selectedAttachments.isNotEmpty
                            ? Icons.check_circle
                            : Icons.cloud_upload_outlined,
                        color: _selectedAttachments.isNotEmpty
                            ? Colors.green
                            : Colors.blue.shade700,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _selectedAttachments.isNotEmpty
                                  ? 'Đã đính kèm ${_selectedAttachments.length}/$_maxKnsImages ảnh'
                                  : 'Tải lên minh chứng (Tối đa $_maxKnsImages ảnh)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _selectedAttachments.isNotEmpty
                                    ? Colors.green.shade800
                                    : Colors.black87,
                              ),
                            ),
                            const Text(
                              'Hỗ trợ JPG, PNG (Tối đa 5MB/ảnh)',
                              style: TextStyle(
                                fontSize: 12,
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
              const SizedBox(height: 8),

              // Render ra danh sách các ảnh đã chọn
              if (_selectedAttachments.isNotEmpty)
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
                        const Icon(Icons.image, color: Colors.blue, size: 20),
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
              const SizedBox(height: 12),
            ],
            // CẢNH BÁO ĐỎ NẾU CHỌN CHẶNG ĐÃ QUA
            if (_isLatePhase) ...[
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.red.shade200),
                ),
                child: Row(
                  children: [
                    Checkbox(
                      value: _confirmLate,
                      activeColor: Colors.red,
                      onChanged: (val) =>
                          setState(() => _confirmLate = val ?? false),
                    ),
                    const Expanded(
                      child: Text(
                        'Cảnh báo: Thời gian ghi nhận cho chặng này đã qua. Bạn có chắc chắn muốn ghi nhận muộn không?',
                        style: TextStyle(
                          color: Colors.red,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],

            // Nút Lưu mở rộng toàn màn hình
            SizedBox(
              width: double.infinity,
              height: 46,
              child: ElevatedButton.icon(
                // Block nút Ghi nhận nếu đang lưu hoặc (Kê khai muộn mà chưa tích xác nhận)
                onPressed: (_isSaving || (_isLatePhase && !_confirmLate))
                    ? null
                    : _saveLearningHours,
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
