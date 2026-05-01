import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'package:excel/excel.dart' hide Border;

class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> {
  bool _isLoading = true;
  bool _isAdmin = false;
  bool _isFocalPoint = false;
  String _userId = '';
  String _userRole = 'tsc';
  String _userDivision = '';
  int? _userDeptId;

  // Lựa chọn bộ lọc
  List<String> _periodOptions = ['Toàn chặng (Tích lũy)'];
  String _selectedPeriod = 'Toàn chặng (Tích lũy)';

  final List<String> _scopeOptions = const [
    'Toàn hệ thống',
    'Khối của tôi',
    'Phòng của tôi',
  ];
  String _selectedScope = 'Toàn hệ thống';

  int _metricIndex = 0; // 0 = Giờ học, 1 = Điểm ứng dụng

  // --- STATE CHO TAB LỊCH SỬ CÁ NHÂN ---
  int _historyMetricIndex = 0; // 0 = Giờ học, 1 = Ứng dụng
  List<dynamic> _learningHistory = [];
  List<dynamic> _appHistory = [];
  bool _isLoadingHistory = true;

  // Dữ liệu hiển thị
  List<Map<String, dynamic>> _allRawData = []; // Dữ liệu hiển thị
  List<dynamic> _periodsConfig = []; // Cấu hình các chặng để gom nhóm lịch sử
  List<Map<String, dynamic>> _top5List = [];
  Map<String, dynamic>? _myRankData;

  @override
  void initState() {
    super.initState();
    _fetchInitialData();
  }

  Future<void> _fetchInitialData() async {
    setState(() {
      _isLoading = true;
      _isLoadingHistory = true;
    });
    _fetchHistoryData(); // Gọi ngầm hàm lấy lịch sử chạy song song
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) return;
      _userId = user.id;

      // 1. Tải Profile để lấy phân quyền & đơn vị
      final profile = await Supabase.instance.client
          .from('profiles')
          .select('role, division, department_id, is_admin')
          .eq('id', _userId)
          .maybeSingle();

      if (profile != null) {
        _userRole = profile['role'] ?? 'tsc';
        _userDivision = profile['division'] ?? '';
        _userDeptId = profile['department_id'];
        _isAdmin = profile['is_admin'] == true;

        // Kiểm tra xem user hiện tại có đích danh là đầu mối (level2_user_id) của phòng này không
        if (_userDeptId != null) {
          final deptInfo = await Supabase.instance.client
              .from('departments')
              .select('level2_user_id')
              .eq('id', _userDeptId!)
              .maybeSingle();

          if (deptInfo != null && deptInfo['level2_user_id'] == _userId) {
            _isFocalPoint = true;
          }
        }
      }

      // 2. Tải danh sách Đợt/Chặng (Lọc theo Role nếu không phải Admin)
      var query = Supabase.instance.client
          .from('learning_periods')
          .select('period_name, start_date, end_date, target_role, is_active');

      // Nếu không phải Admin, chỉ cho xem chặng thi đua của khối mình
      if (!_isAdmin) {
        query = query.eq('target_role', _userRole);
      }

      final periodsRes = await query.order('start_date', ascending: true);
      _periodsConfig =
          periodsRes; // Lưu lại để dùng cho việc phân nhóm danh sách
      List<String> fetchedPeriods = [];
      String? activePeriodName;
      final now = DateTime.now();

      for (var p in periodsRes) {
        String pName = p['period_name'] as String;
        DateTime? sDate = DateTime.tryParse(p['start_date'] ?? '');
        DateTime? eDate = DateTime.tryParse(p['end_date'] ?? '');

        // Chỉ gắn nhãn (Đang Active) và làm mặc định nếu Admin mở VÀ ngày hiện tại thực sự nằm trong chặng
        if (p['is_active'] == true && sDate != null && eDate != null) {
          if (now.isAfter(sDate.subtract(const Duration(days: 1))) &&
              now.isBefore(eDate.add(const Duration(days: 1)))) {
            pName = '$pName (Đang Active)';
            activePeriodName = pName;
          }
        }
        fetchedPeriods.add(pName);
      }

      // 3. Tải toàn bộ Data để xử lý Ranking
      await _aggregateLeaderboardData(periodsRes);

      if (mounted) {
        setState(() {
          _periodOptions = ['Toàn chặng (Tích lũy)', ...fetchedPeriods];

          // Tự động trỏ bộ lọc vào đợt đang Active
          if (activePeriodName != null) {
            _selectedPeriod = activePeriodName;
          } else if (fetchedPeriods.isNotEmpty) {
            _selectedPeriod = fetchedPeriods
                .last; // Fallback: Nếu không có đợt active, lấy đợt gần nhất
          } else {
            _selectedPeriod = 'Toàn chặng (Tích lũy)';
          }

          _isLoading = false;
        });
        _processRanking(); // Tính toán vị trí ban đầu
      }
    } catch (e) {
      debugPrint('Lỗi tải dữ liệu báo cáo: $e');
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Lỗi tải dữ liệu DB: $e',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 10), // Hiện 10s để kịp đọc
          ),
        );
      }
    }
  }

  // --- CÁC HÀM XỬ LÝ LỊCH SỬ CÁ NHÂN ---
  Future<void> _fetchHistoryData() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // 1. Lấy giờ học (Tách try-catch riêng biệt để an toàn dữ liệu)
      try {
        final hoursRes = await Supabase.instance.client
            .from('learning_hours')
            .select('id, course_name, duration_minutes, platform, created_at')
            .eq('user_id', userId)
            .order('created_at', ascending: false);
        _learningHistory = hoursRes;
      } catch (e) {
        debugPrint('Lỗi lấy giờ học: $e');
      }

      // 2. Lấy ứng dụng
      try {
        final appsRes = await Supabase.instance.client
            .from('practical_applications')
            .select(
              'course_name, gamification_points, created_at, key_learnings, practical_results, ai_feedback',
            )
            .eq('user_id', userId)
            .order('created_at', ascending: false);
        _appHistory = appsRes;
      } catch (e) {
        debugPrint('Lỗi lấy ứng dụng: $e');
      }

      if (mounted) {
        setState(() => _isLoadingHistory = false);
      }
    } catch (e) {
      if (mounted) setState(() => _isLoadingHistory = false);
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
              const Text(
                'Kiến thức tâm đắc:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                item['key_learnings']?.toString() ?? 'Không có dữ liệu',
                style: const TextStyle(color: Colors.black54, fontSize: 13),
              ),
              const SizedBox(height: 12),
              const Text(
                'Thực tế áp dụng:',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
              ),
              const SizedBox(height: 4),
              Text(
                item['practical_results']?.toString() ?? 'Không có dữ liệu',
                style: const TextStyle(color: Colors.black54, fontSize: 13),
              ),
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

  // Hàm gom dữ liệu 1 lần duy nhất từ Server để tối ưu
  Future<void> _aggregateLeaderboardData(List<dynamic> allPeriodsConfig) async {
    final profiles = await Supabase.instance.client
        .from('profiles')
        .select(
          'id, full_name, division, department_id, role, departments!profiles_department_id_fkey(department_name)',
        );

    final apps = await Supabase.instance.client
        .from('practical_applications')
        .select(
          'user_id, gamification_points, is_shared_group, coffee_talk_name, is_speaker, created_at, evidence_url',
        );

    final hours = await Supabase.instance.client
        .from('learning_hours')
        .select('user_id, duration_minutes, created_at, evidence_url');

    Map<String, Map<String, dynamic>> userStats = {};
    for (var p in profiles) {
      // Lấy tên phòng từ bảng departments (join), nếu không có thì fallback về ID
      String deptName = p['department_id']?.toString() ?? '';
      if (p['departments'] != null &&
          p['departments']['department_name'] != null) {
        deptName = p['departments']['department_name'].toString();
      }

      userStats[p['id']] = {
        'id': p['id'],
        'name': p['full_name'] ?? 'Ẩn danh',
        'division': p['division'] ?? '',
        'department_id': p['department_id'],
        'department_name': deptName, // Thêm tên phòng
        'role': p['role'] ?? 'tsc',
        'total_points': 0, 'total_hours': 0,
        'active_points': 0, 'active_hours': 0,
        'period_points': 0, 'period_hours': 0,
        // Cột phụ cho xuất báo cáo
        'products': 0, 'shares': 0, 'coffee': 0, 'speakers': 0,
      };
    }

    // Xử lý Điểm
    for (var app in apps) {
      String uid = app['user_id'];
      if (userStats.containsKey(uid)) {
        int pts = (app['gamification_points'] as num?)?.toInt() ?? 0;
        DateTime? date = DateTime.tryParse(app['created_at'] ?? '');

        userStats[uid]!['total_points'] += pts;
        userStats[uid]!['products'] += 1;
        if (app['is_shared_group'] == true) userStats[uid]!['shares'] += 1;
        if (app['is_speaker'] == true) userStats[uid]!['speakers'] += 1;
        if (app['coffee_talk_name'] != null &&
            app['coffee_talk_name'].toString().isNotEmpty) {
          userStats[uid]!['coffee'] += 1;
        }

        if (date != null) {
          // Tính điểm cho chặng Active
          final roleConfig = allPeriodsConfig
              .where(
                (p) =>
                    p['target_role'] == userStats[uid]!['role'] &&
                    p['is_active'] == true,
              )
              .toList();
          if (roleConfig.isNotEmpty) {
            DateTime? s = DateTime.tryParse(
              roleConfig.first['start_date'] ?? '',
            );
            DateTime? e = DateTime.tryParse(roleConfig.first['end_date'] ?? '');
            if (s != null &&
                e != null &&
                date.isAfter(s.subtract(const Duration(days: 1))) &&
                date.isBefore(e.add(const Duration(days: 1)))) {
              userStats[uid]!['active_points'] += pts;
            }
          }
          // Lưu raw date để lát lọc theo từng chặng cụ thể
          userStats[uid]!['raw_app_dates'] ??= [];
          (userStats[uid]!['raw_app_dates'] as List).add({
            'date': date,
            'val': pts,
          });
        }
      }
    }

    // Xử lý Giờ học
    for (var h in hours) {
      String uid = h['user_id'];
      if (userStats.containsKey(uid)) {
        int mins = (h['duration_minutes'] as num?)?.toInt() ?? 0;
        DateTime? date = DateTime.tryParse(h['created_at'] ?? '');

        userStats[uid]!['total_hours'] += mins;

        if (date != null) {
          // Tính giờ cho chặng Active
          final roleConfig = allPeriodsConfig
              .where(
                (p) =>
                    p['target_role'] == userStats[uid]!['role'] &&
                    p['is_active'] == true,
              )
              .toList();
          if (roleConfig.isNotEmpty) {
            DateTime? s = DateTime.tryParse(
              roleConfig.first['start_date'] ?? '',
            );
            DateTime? e = DateTime.tryParse(roleConfig.first['end_date'] ?? '');
            if (s != null &&
                e != null &&
                date.isAfter(s.subtract(const Duration(days: 1))) &&
                date.isBefore(e.add(const Duration(days: 1)))) {
              userStats[uid]!['active_hours'] += mins;
            }
          }
          userStats[uid]!['raw_hour_dates'] ??= [];
          (userStats[uid]!['raw_hour_dates'] as List).add({
            'date': date,
            'val': mins,
          });
        }
      }
    }

    // Nếu chọn 1 chặng cụ thể, ta cần tính lại point/hour tại thời điểm Process
    _allRawData = userStats.values.toList();
    // Cache lại biến config để dùng trong _processRanking
    _allRawData.add({'config_helper': allPeriodsConfig});
  }

  void _processRanking() {
    if (_allRawData.isEmpty) return;

    final allPeriodsConfig = _allRawData.last['config_helper'] as List<dynamic>;
    var usersOnly = _allRawData.sublist(0, _allRawData.length - 1);

    // 1. Gán giá trị So sánh dựa trên Period đang chọn
    for (var u in usersOnly) {
      if (_selectedPeriod == 'Toàn chặng (Tích lũy)') {
        u['sort_points'] = u['total_points'];
        u['sort_hours'] = u['total_hours'];
      } else {
        // Chặng cụ thể (loại bỏ chuỗi " (Đang Active)" trên giao diện để match chuẩn với Database)
        String searchPeriodName = _selectedPeriod.replaceAll(
          ' (Đang Active)',
          '',
        );
        int periodPts = 0;
        int periodHrs = 0;
        final specificConfig = allPeriodsConfig
            .where((p) => p['period_name'] == searchPeriodName)
            .toList();
        if (specificConfig.isNotEmpty) {
          DateTime? s = DateTime.tryParse(
            specificConfig.first['start_date'] ?? '',
          );
          DateTime? e = DateTime.tryParse(
            specificConfig.first['end_date'] ?? '',
          );
          if (s != null && e != null) {
            if (u['raw_app_dates'] != null) {
              for (var item in (u['raw_app_dates'] as List)) {
                if (item['date'].isAfter(s.subtract(const Duration(days: 1))) &&
                    item['date'].isBefore(e.add(const Duration(days: 1)))) {
                  periodPts += item['val'] as int;
                }
              }
            }
            if (u['raw_hour_dates'] != null) {
              for (var item in (u['raw_hour_dates'] as List)) {
                if (item['date'].isAfter(s.subtract(const Duration(days: 1))) &&
                    item['date'].isBefore(e.add(const Duration(days: 1)))) {
                  periodHrs += item['val'] as int;
                }
              }
            }
          }
        }
        u['sort_points'] = periodPts;
        u['sort_hours'] = periodHrs;
      }
    }

    // 2. Lọc theo Phạm vi (Scope)
    var filtered = usersOnly.where((u) {
      if (_selectedScope == 'Khối của tôi') {
        return u['division'] == _userDivision;
      }
      if (_selectedScope == 'Phòng của tôi') {
        return u['department_id'] == _userDeptId;
      }
      return true; // Toàn hệ thống
    }).toList();

    // 3. Lọc bỏ những người có điểm/giờ = 0 để BXH không bị loãng
    filtered = filtered.where((u) {
      return _metricIndex == 0 ? (u['sort_hours'] > 0) : (u['sort_points'] > 0);
    }).toList();

    // 4. Sắp xếp theo Tiêu chí (Giờ học hoặc Điểm)
    if (_metricIndex == 0) {
      filtered.sort(
        (a, b) => (b['sort_hours'] as int).compareTo(a['sort_hours'] as int),
      );
    } else {
      filtered.sort(
        (a, b) => (b['sort_points'] as int).compareTo(a['sort_points'] as int),
      );
    }

    // 5. Tìm hạng của chính mình
    int myIndex = filtered.indexWhere((u) => u['id'] == _userId);
    if (myIndex != -1) {
      _myRankData = {...filtered[myIndex], 'rank': myIndex + 1};
    } else {
      _myRankData = null; // Chưa có hạng (Điểm = 0)
    }

    // 6. Lấy Top 5
    setState(() {
      _top5List = filtered.take(5).toList();
    });
  }

  Future<void> _exportData({
    Map<String, dynamic>? specificUser,
    bool isHRReport = true,
  }) async {
    // Chặn xuất báo cáo trên Mobile, chỉ cho phép trên Web
    if (!kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Tính năng xuất báo cáo Excel hiện chỉ hỗ trợ trên phiên bản Web (Máy tính).',
            ),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    try {
      var excel = Excel.createExcel();
      List<dynamic> exportList = [];
      String fileName = "";
      final timestamp = DateTime.now()
          .toString()
          .replaceAll(RegExp(r'[:.-]'), '')
          .substring(0, 14);

      if (specificUser != null) {
        exportList = [specificUser];
        fileName = "BaoCao_CaNhan_${specificUser['name']}_$timestamp.xlsx";
      } else if (_isAdmin) {
        var allUsers = _allRawData.sublist(0, _allRawData.length - 1);

        if (isHRReport) {
          // Báo cáo Khối Nhân sự: CHỈ lọc danh sách cán bộ có role là 'kns'
          exportList = allUsers.where((u) => u['role'] == 'kns').toList();
          fileName = "BaoCao_KhoiNS_$timestamp.xlsx";
        } else {
          // Báo cáo TSC: Chỉ lọc danh sách cán bộ có role là 'tsc'
          exportList = allUsers.where((u) => u['role'] == 'tsc').toList();
          fileName = "BaoCao_TSC_$timestamp.xlsx";
        }
      } else {
        // Đầu mối chỉ xuất được dữ liệu của phòng mình
        exportList = _allRawData
            .sublist(0, _allRawData.length - 1)
            .where((u) => u['department_id'] == _userDeptId)
            .toList();
        fileName = "BaoCao_DonVi_PhongBan_$timestamp.xlsx";
      }

      if (exportList.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Không có dữ liệu!')));
        }
        return;
      }

      Sheet sheet1 = excel['Bao Cao'];
      excel.delete('Sheet1');

      // 1. Lấy tên chặng đang được chọn trên UI (Lọc bỏ chuỗi " (Đang Active)" nếu có để báo cáo sạch đẹp)
      String exportPhaseName = _selectedPeriod.replaceAll(' (Đang Active)', '');

      // 2. Định nghĩa Header dựa theo loại báo cáo
      List<CellValue> header;
      if (isHRReport) {
        header = [
          TextCellValue('Họ và tên'),
          TextCellValue('Phòng ban'),
          TextCellValue('Khối'),
          TextCellValue('Chặng/Đợt'),
          TextCellValue('Giờ học'),
          TextCellValue('Số SP'),
          TextCellValue('Share Group'),
          TextCellValue('Coffee Talk'),
          TextCellValue('Diễn giả'),
          TextCellValue('Điểm'),
          TextCellValue('Minh Chứng'),
        ];
      } else {
        // Báo cáo TSC rút gọn theo yêu cầu
        header = [
          TextCellValue('Họ và tên'),
          TextCellValue('Phòng ban'),
          TextCellValue('Khối'),
          TextCellValue('Chặng/Đợt'),
          TextCellValue('Tổng Giờ học'),
          TextCellValue('Tổng Số SP'),
          TextCellValue('Tổng Điểm'),
        ];
      }
      sheet1.appendRow(header);

      // 3. Đổ dữ liệu vào các dòng
      for (var row in exportList) {
        if (isHRReport) {
          String links = "";
          if (row['raw_app_dates'] != null) {
            links += (row['raw_app_dates'] as List)
                .where((i) => i['evidence_url'] != null)
                .map((i) => i['evidence_url'])
                .join("; ");
          }
          sheet1.appendRow([
            TextCellValue(row['name'] ?? ''),
            TextCellValue(row['department_name'] ?? ''),
            TextCellValue(row['division'] ?? ''),
            TextCellValue(exportPhaseName),
            IntCellValue(row['sort_hours'] ?? row['total_hours'] ?? 0),
            IntCellValue(row['products'] ?? 0),
            IntCellValue(row['shares'] ?? 0),
            IntCellValue(row['coffee'] ?? 0),
            IntCellValue(row['speakers'] ?? 0),
            IntCellValue(row['sort_points'] ?? row['total_points'] ?? 0),
            TextCellValue(links),
          ]);
        } else {
          sheet1.appendRow([
            TextCellValue(row['name'] ?? ''),
            TextCellValue(row['department_name'] ?? ''),
            TextCellValue(row['division'] ?? ''),
            TextCellValue(exportPhaseName),
            IntCellValue(row['sort_hours'] ?? row['total_hours'] ?? 0),
            IntCellValue(row['products'] ?? 0),
            IntCellValue(row['sort_points'] ?? row['total_points'] ?? 0),
          ]);
        }
      }

      // 4. Lưu file
      String? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Lưu báo cáo Excel',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
      );

      if (outputFile != null) {
        final fileBytes = excel.encode();
        if (fileBytes != null) {
          File(outputFile)
            ..createSync(recursive: true)
            ..writeAsBytesSync(fileBytes);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Xuất Excel thành công!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      }
    } catch (e) {
      debugPrint("Lỗi xuất Excel: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi xuất file: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteLearningRecord(String recordId, String courseName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa'),
        content: Text(
          'Bạn có chắc chắn muốn xóa khóa học "$courseName" không?\nDữ liệu sau khi xóa sẽ bị trừ khỏi bảng xếp hạng và không thể khôi phục.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Xóa',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoadingHistory = true);
    try {
      await Supabase.instance.client
          .from('learning_hours')
          .delete()
          .eq('id', recordId);

      // Xóa thành công thì tải lại toàn bộ Data để Cập nhật BXH và Lịch sử
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã xóa khóa học thành công'),
            backgroundColor: Colors.green,
          ),
        );
        _fetchInitialData();
      }
    } catch (e) {
      setState(() => _isLoadingHistory = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi khi xóa: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // Kiểm tra xem người dùng có quyền xuất báo cáo không (Admin hoặc đích danh Đầu mối)
    bool canExport = _isAdmin || _isFocalPoint;

    return DefaultTabController(
      length: canExport ? 3 : 2,
      child: Scaffold(
        appBar: AppBar(
          flexibleSpace: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Color(0xFF004A85),
                  Color(0xFF0075C2),
                ], // Gradient Xanh VietinBank
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
              ),
            ),
          ),
          foregroundColor: Colors.white,
          title: const Text(
            'Báo cáo & Dashboard',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          bottom: TabBar(
            labelColor: Colors.white,
            unselectedLabelColor: Colors.white70,
            indicatorColor: const Color(0xFFE31837), // Màu đỏ VietinBank
            indicatorWeight: 3.0,
            tabs: [
              const Tab(text: 'Cá nhân', icon: Icon(Icons.history)),
              const Tab(text: 'BXH', icon: Icon(Icons.leaderboard)),
              if (canExport)
                const Tab(text: 'Xuất báo cáo', icon: Icon(Icons.download)),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            // TAB 1: LỊCH SỬ CÁ NHÂN (Chỉ hiện của chính mình)
            Column(
              children: [
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        label: Text('Giờ học đã khai'),
                        icon: Icon(Icons.timer),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text('Sản phẩm Ứng dụng'),
                        icon: Icon(Icons.stars),
                      ),
                    ],
                    selected: {_historyMetricIndex},
                    onSelectionChanged: (Set<int> newSelection) {
                      setState(() => _historyMetricIndex = newSelection.first);
                    },
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith<Color>((
                        states,
                      ) {
                        return states.contains(WidgetState.selected)
                            ? Colors.blue.shade50
                            : Colors.transparent;
                      }),
                    ),
                  ),
                ),
                const Divider(height: 1, thickness: 1),
                Expanded(
                  child: _isLoadingHistory
                      ? const Center(child: CircularProgressIndicator())
                      : _historyMetricIndex == 0
                      ? (_learningHistory.isEmpty
                            ? const Center(
                                child: Text(
                                  'Chưa có dữ liệu giờ học',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              )
                            : Builder(
                                builder: (context) {
                                  // 1. Phân nhóm dữ liệu theo chặng
                                  Map<String, List<dynamic>> groupedItems = {};
                                  String activePeriodName = "";

                                  for (var item in _learningHistory) {
                                    DateTime? date = DateTime.tryParse(
                                      item['created_at'] ?? '',
                                    );
                                    String periodName =
                                        "Khác (Ngoài thời gian thi đua)";

                                    if (date != null &&
                                        _periodsConfig.isNotEmpty) {
                                      for (var p in _periodsConfig) {
                                        DateTime? sDate = DateTime.tryParse(
                                          p['start_date'] ?? '',
                                        );
                                        DateTime? eDate = DateTime.tryParse(
                                          p['end_date'] ?? '',
                                        );

                                        if (sDate != null && eDate != null) {
                                          if (date.isAfter(
                                                sDate.subtract(
                                                  const Duration(days: 1),
                                                ),
                                              ) &&
                                              date.isBefore(
                                                eDate.add(
                                                  const Duration(days: 1),
                                                ),
                                              )) {
                                            String pName = p['period_name'];
                                            if (p['is_active'] == true) {
                                              pName = '$pName (Đang Active)';
                                              activePeriodName = pName;
                                            }
                                            periodName = pName;
                                            break;
                                          }
                                        }
                                      }
                                    }
                                    groupedItems
                                        .putIfAbsent(periodName, () => [])
                                        .add(item);
                                  }

                                  // 2. Sắp xếp: Ưu tiên chặng Active lên đỉnh
                                  List<String> sortedKeys = groupedItems.keys
                                      .toList();
                                  sortedKeys.sort((a, b) {
                                    if (a == activePeriodName) return -1;
                                    if (b == activePeriodName) return 1;
                                    return b.compareTo(
                                      a,
                                    ); // Các chặng khác sắp xếp giảm dần
                                  });

                                  // 3. Render giao diện có khả năng Expand/Collapse
                                  return ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    itemCount: sortedKeys.length,
                                    itemBuilder: (context, index) {
                                      String currentPeriod = sortedKeys[index];
                                      List<dynamic> periodCourses =
                                          groupedItems[currentPeriod]!;
                                      bool isActivePeriod =
                                          currentPeriod == activePeriodName;

                                      return Theme(
                                        data: Theme.of(context).copyWith(
                                          dividerColor: Colors.transparent,
                                        ),
                                        child: ExpansionTile(
                                          initiallyExpanded:
                                              isActivePeriod, // Tự động mở sổ chặng đang Active
                                          title: Text(
                                            currentPeriod,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                              color: isActivePeriod
                                                  ? Colors.blue.shade800
                                                  : Colors.black87,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${periodCourses.length} khóa học đã khai',
                                          ),
                                          leading: Icon(
                                            isActivePeriod
                                                ? Icons.local_fire_department
                                                : Icons.folder_copy,
                                            color: isActivePeriod
                                                ? Colors.orange
                                                : Colors.grey,
                                          ),
                                          children: periodCourses.map((item) {
                                            return Card(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 4,
                                                  ),
                                              elevation: 1,
                                              color: Colors.white,
                                              child: ListTile(
                                                contentPadding:
                                                    const EdgeInsets.only(
                                                      left: 16,
                                                      right: 8,
                                                    ),
                                                leading: const CircleAvatar(
                                                  backgroundColor: Colors.green,
                                                  radius: 18,
                                                  child: Icon(
                                                    Icons.timer,
                                                    color: Colors.white,
                                                    size: 18,
                                                  ),
                                                ),
                                                title: Text(
                                                  item['course_name'] ?? '',
                                                  style: const TextStyle(
                                                    fontWeight: FontWeight.bold,
                                                    fontSize: 14,
                                                  ),
                                                ),
                                                subtitle: Text(
                                                  '${item['platform']} • ${_formatDate(item['created_at'])}',
                                                  style: const TextStyle(
                                                    fontSize: 12,
                                                  ),
                                                ),
                                                trailing: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      '+${item['duration_minutes']}p',
                                                      style: const TextStyle(
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: Colors.green,
                                                        fontSize: 15,
                                                      ),
                                                    ),
                                                    IconButton(
                                                      icon: const Icon(
                                                        Icons.delete_outline,
                                                        color: Colors.redAccent,
                                                        size: 22,
                                                      ),
                                                      tooltip: 'Xóa',
                                                      onPressed: () =>
                                                          _deleteLearningRecord(
                                                            item['id']
                                                                .toString(),
                                                            item['course_name'] ??
                                                                '',
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      );
                                    },
                                  );
                                },
                              ))
                      : (_appHistory.isEmpty
                            ? const Center(
                                child: Text(
                                  'Chưa có dữ liệu ứng dụng',
                                  style: TextStyle(color: Colors.grey),
                                ),
                              )
                            : ListView.builder(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                itemCount: _appHistory.length,
                                itemBuilder: (context, index) {
                                  final item = _appHistory[index];
                                  return Card(
                                    margin: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 6,
                                    ),
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
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              )),
                ),
              ],
            ),

            // TAB 2: BẢNG XẾP HẠNG
            Column(
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  color: Colors.white,
                  child: Row(
                    children: [
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Chọn Thời Gian',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 0,
                            ),
                          ),
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedPeriod,
                            underline: const SizedBox(),
                            items: _periodOptions
                                .map(
                                  (val) => DropdownMenuItem(
                                    value: val,
                                    child: Text(
                                      val,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              setState(() => _selectedPeriod = val!);
                              _processRanking();
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: InputDecorator(
                          decoration: const InputDecoration(
                            labelText: 'Phạm Vi',
                            border: OutlineInputBorder(),
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 0,
                            ),
                          ),
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: _selectedScope,
                            underline: const SizedBox(),
                            items: _scopeOptions
                                .map(
                                  (val) => DropdownMenuItem(
                                    value: val,
                                    child: Text(
                                      val,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 13),
                                    ),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              setState(() => _selectedScope = val!);
                              _processRanking();
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  color: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  width: double.infinity,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        label: Text('🏆 Xếp hạng Giờ học'),
                        icon: Icon(Icons.timer),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text('🔥 Xếp hạng Điểm số'),
                        icon: Icon(Icons.stars),
                      ),
                    ],
                    selected: {_metricIndex},
                    onSelectionChanged: (Set<int> newSelection) {
                      setState(() => _metricIndex = newSelection.first);
                      _processRanking();
                    },
                  ),
                ),
                const Divider(height: 1, thickness: 1),
                Expanded(
                  child: _top5List.isEmpty
                      ? const Center(
                          child: Text(
                            'Chưa có dữ liệu cho bộ lọc này.',
                            style: TextStyle(color: Colors.grey),
                          ),
                        )
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _top5List.length,
                          itemBuilder: (context, index) {
                            final user = _top5List[index];
                            final isMe = user['id'] == _userId;
                            return Card(
                              elevation: isMe ? 4 : 1,
                              color: isMe ? Colors.amber.shade50 : Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                                side: BorderSide(
                                  color: isMe
                                      ? Colors.amber
                                      : Colors.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: ListTile(
                                leading: CircleAvatar(
                                  backgroundColor: index == 0
                                      ? Colors.amber
                                      : (index == 1
                                            ? Colors.grey.shade400
                                            : (index == 2
                                                  ? Colors.brown.shade300
                                                  : Colors.blue.shade50)),
                                  child: Text(
                                    '${index + 1}',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: index < 3
                                          ? Colors.white
                                          : Colors.blue.shade900,
                                    ),
                                  ),
                                ),
                                title: Text(
                                  user['name'],
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    color: isMe
                                        ? Colors.amber.shade900
                                        : Colors.black87,
                                  ),
                                ),
                                subtitle: Text(
                                  [user['department_name'], user['division']]
                                      .where(
                                        (e) =>
                                            e != null &&
                                            e.toString().trim().isNotEmpty,
                                      )
                                      .join(' - '),
                                  style: const TextStyle(fontSize: 12),
                                ),
                                trailing: Text(
                                  '${_metricIndex == 0 ? user['sort_hours'] : user['sort_points']} ${_metricIndex == 0 ? "phút" : "điểm"}',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 16,
                                    color: _metricIndex == 0
                                        ? Colors.green.shade700
                                        : Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                ),
                // Sticky Card "Thành tích của Bạn"
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.05),
                        blurRadius: 10,
                        offset: const Offset(0, -5),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: _myRankData != null
                            ? Colors.blue.shade800
                            : Colors.grey,
                        child: Text(
                          _myRankData != null ? '${_myRankData!['rank']}' : '-',
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Thành tích của Bạn',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade900,
                              ),
                            ),
                            Text(
                              _myRankData != null
                                  ? 'Bạn đang xếp thứ ${_myRankData!['rank']} trong ${_selectedScope.toLowerCase()}'
                                  : 'Bạn chưa có thành tích trong giai đoạn này.',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${_myRankData != null ? (_metricIndex == 0 ? _myRankData!['sort_hours'] : _myRankData!['sort_points']) : 0} ${_metricIndex == 0 ? "phút" : "điểm"}',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                          color: _metricIndex == 0
                              ? Colors.green.shade700
                              : Colors.blue.shade700,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            // TAB 3: XUẤT BÁO CÁO (Tách biệt Admin và Đầu mối)
            if (canExport)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.analytics,
                        size: 80,
                        color: Colors.blue.shade100,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _isAdmin ? 'Quản trị hệ thống' : 'Báo cáo đơn vị',
                        style: const TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _isAdmin
                            ? 'Vui lòng chọn loại báo cáo bạn muốn trích xuất.'
                            : 'Tải xuống dữ liệu tổng hợp của cán bộ thuộc phòng của bạn.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.grey),
                      ),
                      const SizedBox(height: 32),
                      if (_isAdmin) ...[
                        SizedBox(
                          width: 250,
                          child: ElevatedButton.icon(
                            onPressed: () => _exportData(isHRReport: false),
                            icon: const Icon(Icons.description),
                            label: const Text('Xuất file Báo cáo TSC'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.blue.shade700,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 12),
                        SizedBox(
                          width: 250,
                          child: ElevatedButton.icon(
                            onPressed: () => _exportData(isHRReport: true),
                            icon: const Icon(Icons.assessment),
                            label: const Text('Xuất file Khối Nhân sự'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF005A9E),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                          ),
                        ),
                      ] else ...[
                        ElevatedButton.icon(
                          onPressed: () => _exportData(),
                          icon: const Icon(Icons.download),
                          label: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16.0,
                              vertical: 12.0,
                            ),
                            child: Text(
                              'Tải báo cáo cấp Phòng',
                              style: TextStyle(fontSize: 16),
                            ),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF005A9E),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
