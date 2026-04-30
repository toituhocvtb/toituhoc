import 'dart:io';
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
  // Trạng thái lưu file minh chứng (KNS)
  String? _selectedFileName;
  String? _selectedFilePath;
  int? _selectedFileSize;
  DateTime? _uploadTimestamp;

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
          _phaseDataList = List<Map<String, dynamic>>.from(periodsRes);
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

    if (_userRole == 'kns' && _selectedFileName == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Khối Nhân sự bắt buộc phải tải lên file minh chứng!'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }
    setState(() => _isSaving = true);

    try {
      final user = Supabase.instance.client.auth.currentUser;
      String? storagePath;

      // Xử lý upload file lên Supabase Storage trước khi insert db
      if (_userRole == 'kns' && _selectedFilePath != null) {
        final file = File(_selectedFilePath!);
        final fileExt = _selectedFileName!.split('.').last;
        // Tạo tên file unique tránh trùng lặp
        final fileName =
            '${user?.id}_${DateTime.now().millisecondsSinceEpoch}.$fileExt';
        storagePath = 'kns_evidence/$fileName';

        await Supabase.instance.client.storage
            .from('learning-evidence')
            .upload(storagePath, file);

        _uploadTimestamp =
            DateTime.now(); // Lưu timestamp thực tế lúc upload xong
      }

      await Supabase.instance.client.from('learning_hours').insert({
        'user_id': user?.id,
        'course_name': course,
        'duration_minutes':
            _totalCalculatedMinutes, // Đẩy tổng số phút đã tính toán
        'phase_batch': _selectedPhase,
        'platform': finalPlatform,
        'completion_date': _completionDate
            .toIso8601String(), // Lưu ngày giờ hoàn thành thực tế
        // Lưu toàn bộ thông tin minh chứng vào DB
        if (_userRole == 'kns' && storagePath != null) ...{
          'evidence_storage_path': storagePath,
          'evidence_file_name': _selectedFileName,
          'evidence_size': _selectedFileSize,
          'upload_timestamp': _uploadTimestamp!.toIso8601String(),
        },
      });

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
        _selectedFileName = null;
        _selectedFilePath = null;
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
                  FilePickerResult? result = await FilePicker.pickFiles(
                    type: FileType.custom,
                    allowedExtensions: [
                      'jpg',
                      'jpeg',
                      'png',
                    ], // Hỗ trợ thêm jpeg
                  );
                  if (!context.mounted) return;

                  if (result != null && result.files.single.path != null) {
                    String originalPath = result.files.single.path!;

                    File finalFile = File(originalPath);
                    String finalFileName = result.files.single.name;

                    try {
                      // Chỉ gọi thư viện nén ảnh nếu đang chạy trên thiết bị Mobile
                      if (Platform.isAndroid || Platform.isIOS) {
                        final lastIndex = originalPath.lastIndexOf(
                          RegExp(r'\.jp|\.pn', caseSensitive: false),
                        );
                        if (lastIndex != -1) {
                          final compressedPath =
                              '${originalPath.substring(0, lastIndex)}_compressed.jpg';

                          var compressedFile =
                              await FlutterImageCompress.compressAndGetFile(
                                originalPath,
                                compressedPath,
                                quality: 70,
                                minWidth: 1080,
                                minHeight: 1080,
                                format: CompressFormat.jpeg,
                              );

                          if (compressedFile != null) {
                            finalFile = File(compressedFile.path);
                            finalFileName = 'compressed_$finalFileName';
                          }
                        }
                      }
                    } catch (e) {
                      debugPrint(
                        'Bỏ qua nén ảnh do môi trường không hỗ trợ: $e',
                      );
                    }

                    // Kiểm tra dung lượng file cuối cùng (file đã nén hoặc file gốc)
                    final sizeInBytes = await finalFile.length();

                    if (sizeInBytes > 5242880) {
                      // Giới hạn 5MB
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'Kích thước ảnh vượt quá 5MB. Vui lòng chọn ảnh nhẹ hơn!',
                          ),
                          backgroundColor: Colors.red,
                        ),
                      );
                      return;
                    }

                    setState(() {
                      _selectedFileName = finalFileName;
                      _selectedFilePath = finalFile.path;
                      _selectedFileSize = sizeInBytes;
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
                    color: _selectedFileName != null
                        ? Colors.green.shade50
                        : Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _selectedFileName != null
                          ? Colors.green.shade400
                          : Colors.grey.shade300,
                      style: BorderStyle.solid,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _selectedFileName != null
                            ? Icons.check_circle
                            : Icons.cloud_upload_outlined,
                        color: _selectedFileName != null
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
                              _selectedFileName != null
                                  ? 'Đã đính kèm minh chứng'
                                  : 'Tải lên minh chứng (Bắt buộc)',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: _selectedFileName != null
                                    ? Colors.green.shade800
                                    : Colors.black87,
                              ),
                            ),
                            if (_selectedFileName != null)
                              Text(
                                _selectedFileName!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              )
                            else
                              const Text(
                                'Hỗ trợ định dạng JPG, PNG (Tối đa 5MB)',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (_selectedFileName != null)
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
                              _selectedFileName = null;
                              _selectedFilePath = null;
                            });
                          },
                        ),
                    ],
                  ),
                ),
              ),
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
