import 'dart:typed_data';

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
  int _knsMaxAi = 20;
  int _tscMaxAi = 10;

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

      // Tải cấu hình điểm chuẩn hóa linh hoạt từ Admin
      final rulesRes = await Supabase.instance.client
          .from('gamification_rules')
          .select('rule_key, points');
      for (var r in rulesRes) {
        if (r['rule_key'] == 'kns_max_ai') _knsMaxAi = r['points'];
        if (r['rule_key'] == 'tsc_max_ai') _tscMaxAi = r['points'];
      }

      // 2. Tải danh sách Đợt/Chặng (Lọc theo Role nếu không phải Admin)
      var query = Supabase.instance.client
          .from('learning_periods')
          .select(
            'period_name, start_date, end_date, claim_cutoff_date, target_role',
          );

      // Nếu không phải Admin, chỉ cho xem chặng thi đua của khối mình
      if (!_isAdmin) {
        if (_userRole == 'all') {
          query = query.inFilter('target_role', [
            'tsc',
            'kns',
          ]); // Phòng B thấy cả 2 đợt
        } else {
          query = query.eq('target_role', _userRole);
        }
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

        // Bỏ qua (ẩn) các chặng chưa đến thời gian bắt đầu
        if (sDate != null && now.isBefore(sDate)) {
          continue;
        }

        // Tự động gắn nhãn (Đang Active) nếu ngày hiện tại nằm trong thời gian diễn ra chặng
        if (sDate != null && eDate != null) {
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
            // Bổ sung completion_date để xếp chặng chính xác
            .select(
              'id, course_name, duration_minutes, platform, created_at, completion_date',
            )
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
            // Lấy thêm id, ai_score và các cờ KNS để render UI chi tiết điểm
            .select(
              'id, course_name, gamification_points, ai_score, is_shared_group, coffee_talk_name, is_speaker, created_at, key_learnings, practical_results, ai_feedback',
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

  // Hàm gom dữ liệu 1 lần duy nhất bằng Bảng Ảo (Siêu nhẹ, siêu tiết kiệm token)
  Future<void> _aggregateLeaderboardData(List<dynamic> allPeriodsConfig) async {
    List<dynamic> events = [];
    int start = 0;
    while (true) {
      final res = await Supabase.instance.client
          .from('v_leaderboard_events')
          .select()
          .range(start, start + 999);
      events.addAll(res);
      if (res.length < 1000) break;
      start += 1000;
    }

    Map<String, Map<String, dynamic>> userStats = {};

    // Khởi tạo data của chính mình để tránh lỗi (dù chưa có điểm)
    final myProfile = await Supabase.instance.client
        .from('profiles')
        .select(
          'full_name, division, department_id, role, departments!profiles_department_id_fkey(department_name)',
        )
        .eq('id', _userId)
        .maybeSingle();

    String myDeptName = '';
    if (myProfile != null && myProfile['departments'] != null) {
      myDeptName = myProfile['departments']['department_name'] ?? '';
    }

    userStats[_userId] = {
      'id': _userId,
      'name': myProfile != null ? (myProfile['full_name'] ?? 'Tôi') : 'Tôi',
      'division': _userDivision,
      'department_id': _userDeptId,
      'department_name': myDeptName,
      'role': _userRole,
      'total_points': 0,
      'total_hours': 0,
      'active_points': 0,
      'active_hours': 0,
      'period_points': 0,
      'period_hours': 0,
      'products': 0,
      'shares': 0,
      'coffee': 0,
      'speakers': 0,
      'raw_app_dates': [],
      'raw_hour_dates': [],
    };

    // Quét trực tiếp các sự kiện từ bảng ảo đã được thu gọn
    for (var ev in events) {
      String uid = ev['user_id']?.toString() ?? '';
      if (uid.isEmpty) continue;

      if (!userStats.containsKey(uid)) {
        userStats[uid] = {
          'id': uid,
          'name': ev['name'] ?? 'Ẩn danh',
          'division': ev['division'] ?? '',
          'department_id': ev['department_id'],
          'department_name': ev['department_name'] ?? '',
          'role': ev['role'] ?? 'tsc',
          'total_points': 0,
          'total_hours': 0,
          'active_points': 0,
          'active_hours': 0,
          'period_points': 0,
          'period_hours': 0,
          'products': 0,
          'shares': 0,
          'coffee': 0,
          'speakers': 0,
          'raw_app_dates': [],
          'raw_hour_dates': [],
        };
      }

      int pts = (ev['points'] as num?)?.toInt() ?? 0;
      int aiPts = (ev['ai_points'] as num?)?.toInt() ?? 0;
      int extraPts = (ev['extra_points'] as num?)?.toInt() ?? 0;
      int hrs = (ev['hours'] as num?)?.toInt() ?? 0;
      DateTime? date = DateTime.tryParse(ev['event_date'] ?? '');

      if (pts > 0) {
        userStats[uid]!['total_points'] += pts;
        userStats[uid]!['products'] += 1;
        if (ev['is_shared_group'] == true) userStats[uid]!['shares'] += 1;
        if (ev['is_speaker'] == true) userStats[uid]!['speakers'] += 1;
        if (ev['coffee_talk_name'] != null &&
            ev['coffee_talk_name'].toString().trim().isNotEmpty) {
          userStats[uid]!['coffee'] += 1;
        }

        if (date != null) {
          (userStats[uid]!['raw_app_dates'] as List).add({
            'date': date,
            'val': pts,
            'ai_val': aiPts,
            'extra_val': extraPts,
            'event_name': ev['event_name'] ?? 'Không rõ',
            'evidence_url': ev['evidence_url'],
            'share': ev['is_shared_group'] == true ? 'Có' : '',
            'speaker': ev['is_speaker'] == true ? 'Có' : '',
            'coffee': ev['coffee_talk_name']?.toString() ?? '',
          });
        }
      }

      if (hrs > 0) {
        userStats[uid]!['total_hours'] += hrs;
        if (date != null) {
          (userStats[uid]!['raw_hour_dates'] as List).add({
            'date': date,
            'val': hrs,
            'event_name': ev['event_name'] ?? 'Không rõ',
            'phase_batch': ev['phase_batch'],
          });
        }
      }
    }

    _allRawData = userStats.values.toList();
    _allRawData.add({'config_helper': allPeriodsConfig});
  }

  void _processRanking() {
    if (_allRawData.isEmpty) return;

    final allPeriodsConfig = _allRawData.last['config_helper'] as List<dynamic>;
    var usersOnly = _allRawData.sublist(0, _allRawData.length - 1);

    // 1. Gán giá trị So sánh dựa trên Period đang chọn
    for (var u in usersOnly) {
      bool isSystemScope = _selectedScope == 'Toàn hệ thống';

      if (_selectedPeriod == 'Toàn chặng (Tích lũy)') {
        int totalPts = 0;
        int totalHrs = 0;

        if (u['raw_app_dates'] != null) {
          for (var item in (u['raw_app_dates'] as List)) {
            if (isSystemScope && u['role'] == 'all') {
              // Chuẩn hóa điểm cho Phòng B khi vào BXH toàn hàng (Bỏ qua điểm cộng)
              double scaled =
                  (item['ai_val'] as int) *
                  (_tscMaxAi / (_knsMaxAi > 0 ? _knsMaxAi : 1));
              totalPts += scaled.round();
            } else {
              totalPts += item['val'] as int; // Bao gồm cả ai_val + extra_val
            }
          }
        }

        if (u['raw_hour_dates'] != null) {
          for (var item in (u['raw_hour_dates'] as List)) {
            totalHrs += item['val'] as int;
          }
        }

        u['sort_points'] = totalPts;
        u['sort_hours'] = totalHrs;
      } else {
        String searchPeriodName = _selectedPeriod;
        if (searchPeriodName.contains(' (')) {
          searchPeriodName = searchPeriodName
              .substring(0, searchPeriodName.indexOf(' ('))
              .trim();
        }

        int periodPts = 0;
        int periodHrs = 0;

        final specificConfig = allPeriodsConfig
            .where(
              (p) =>
                  (p['period_name']?.toString().trim() ?? '') ==
                  searchPeriodName,
            )
            .toList();

        DateTime? s;
        DateTime? e;
        if (specificConfig.isNotEmpty) {
          s = DateTime.tryParse(specificConfig.first['start_date'] ?? '');
          e = DateTime.tryParse(specificConfig.first['end_date'] ?? '');
        }

        if (s != null && e != null && u['raw_app_dates'] != null) {
          for (var item in (u['raw_app_dates'] as List)) {
            if (item['date'] != null &&
                item['date'].isAfter(s.subtract(const Duration(days: 1))) &&
                item['date'].isBefore(e.add(const Duration(days: 1)))) {
              if (isSystemScope && u['role'] == 'all') {
                // Chuẩn hóa điểm cho Phòng B khi vào BXH toàn hàng (Bỏ qua điểm cộng)
                double scaled =
                    (item['ai_val'] as int) *
                    (_tscMaxAi / (_knsMaxAi > 0 ? _knsMaxAi : 1));
                periodPts += scaled.round();
              } else {
                periodPts += item['val'] as int;
              }
            }
          }
        }

        if (u['raw_hour_dates'] != null) {
          for (var item in (u['raw_hour_dates'] as List)) {
            String itemPhaseRaw = item['phase_batch']?.toString().trim() ?? '';
            String cleanItemPhase = itemPhaseRaw.contains(' (')
                ? itemPhaseRaw.substring(0, itemPhaseRaw.indexOf(' (')).trim()
                : itemPhaseRaw;

            final bool phaseMatched = cleanItemPhase == searchPeriodName;
            final bool dateMatched =
                s != null &&
                e != null &&
                item['date'] != null &&
                item['date'].isAfter(s.subtract(const Duration(days: 1))) &&
                item['date'].isBefore(e.add(const Duration(days: 1)));

            if (phaseMatched || dateMatched) {
              periodHrs += item['val'] as int;
            }
          }
        }

        u['sort_points'] = periodPts;
        u['sort_hours'] = periodHrs;
      }
    }

    // 2. Lọc theo Phạm vi (Scope) VÀ Role của Đợt/Chặng
    var filtered = usersOnly.where((u) {
      // 2.1. Lọc theo Role của Đợt/Chặng đang chọn
      if (_selectedPeriod != 'Toàn chặng (Tích lũy)') {
        String searchPeriodName = _selectedPeriod;
        if (searchPeriodName.contains(' (')) {
          searchPeriodName = searchPeriodName
              .substring(0, searchPeriodName.indexOf(' ('))
              .trim();
        }

        final specificConfig = allPeriodsConfig
            .where(
              (p) =>
                  (p['period_name']?.toString().trim() ?? '') ==
                  searchPeriodName,
            )
            .toList();

        if (specificConfig.isNotEmpty) {
          String targetRole = specificConfig.first['target_role'] ?? '';
          // Cho phép role 'all' (Phòng B) lọt qua mọi rào cản Role của đợt
          if (u['role'] != targetRole && u['role'] != 'all') {
            return false;
          }
        }
      }

      // 2.2. Lọc theo Phạm vi (Scope)
      if (_selectedScope == 'Khối của tôi') {
        return u['division'] == _userDivision;
      }
      if (_selectedScope == 'Phòng của tôi') {
        return u['department_id'] == _userDeptId;
      }
      // Toàn hệ thống: TSC và B (all) hiển thị chung, loại bỏ KNS thuần (Phòng A)
      if (_selectedScope == 'Toàn hệ thống') {
        if (u['role'] == 'kns') return false;
      }
      return true;
    }).toList();

    debugPrint(
      '[BXH] period=$_selectedPeriod | scope=$_selectedScope | metric=$_metricIndex | usersOnly=${usersOnly.length}',
    );

    debugPrint(
      '[BXH] trước filter: '
      'withHours=${usersOnly.where((u) => ((u['sort_hours'] ?? 0) as int) > 0).length}, '
      'withPoints=${usersOnly.where((u) => ((u['sort_points'] ?? 0) as int) > 0).length}',
    );

    // 3. Lọc bỏ những người có điểm/giờ = 0 để BXH không bị loãng
    filtered = filtered.where((u) {
      final h = (u['sort_hours'] as int?) ?? 0;
      final p = (u['sort_points'] as int?) ?? 0;

      // Cho phép người có điểm HOẶC có giờ học đều được hiển thị để tránh lỗi BXH trắng
      return h > 0 || p > 0;
    }).toList();

    debugPrint('[BXH] sau filter: ${filtered.length}');

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
          TextCellValue('Chặng/Đợt đang lọc'),
          TextCellValue('Loại dữ liệu'),
          TextCellValue('Tên Khóa học / Ứng dụng'),
          TextCellValue('Điểm / Số Phút'),
          TextCellValue('Share Group'),
          TextCellValue('Diễn giả'),
          TextCellValue('Coffee Talk'),
          TextCellValue('Link URL Minh Chứng'),
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

      // Lấy ngày bắt đầu/kết thúc để lọc dữ liệu rác không thuộc chặng
      DateTime? sDate;
      DateTime? eDate;
      if (_selectedPeriod != 'Toàn chặng (Tích lũy)') {
        final specificConfig =
            (_allRawData.last['config_helper'] as List<dynamic>)
                .where(
                  (p) =>
                      (p['period_name']?.toString().trim() ?? '') ==
                      exportPhaseName,
                )
                .toList();
        if (specificConfig.isNotEmpty) {
          sDate = DateTime.tryParse(specificConfig.first['start_date'] ?? '');
          eDate = DateTime.tryParse(specificConfig.first['end_date'] ?? '');
        }
      }

      bool isItemInPeriod(DateTime? itemDate) {
        if (_selectedPeriod == 'Toàn chặng (Tích lũy)') return true;
        if (sDate != null && eDate != null && itemDate != null) {
          return itemDate.isAfter(sDate.subtract(const Duration(days: 1))) &&
              itemDate.isBefore(eDate.add(const Duration(days: 1)));
        }
        return false;
      }

      // Hàm tự động gen Full Link URL từ Storage và tạo Hyperlink cho Excel
      CellValue getExcelHyperlink(String? rawPaths) {
        if (rawPaths == null || rawPaths.trim().isEmpty) {
          return TextCellValue('');
        }

        final String bucketName = 'learning-evidence';

        List<String> paths = rawPaths.split(';');
        String firstPath = paths.first.trim();

        if (firstPath.isEmpty) {
          return TextCellValue('');
        }

        // Tạo link Public URL
        String publicUrl = Supabase.instance.client.storage
            .from(bucketName)
            .getPublicUrl(firstPath);

        // Thiết lập Giao diện text của link hiển thị trên Excel (Hiển thị xem có bao nhiêu ảnh)
        String linkText = paths.length > 1
            ? 'Xem Minh Chứng (+${paths.length - 1} ảnh)'
            : 'Xem Minh Chứng';

        // Bọc trong hàm HYPERLINK() của Excel để tạo link có thể click trực tiếp
        return FormulaCellValue('HYPERLINK("$publicUrl", "$linkText")');
      }

      // 3. Đổ dữ liệu vào các dòng
      for (var row in exportList) {
        if (isHRReport) {
          // Bóc tách Điểm Ứng dụng thành từng dòng
          if (row['raw_app_dates'] != null) {
            for (var app in (row['raw_app_dates'] as List)) {
              if (!isItemInPeriod(app['date'])) continue;
              sheet1.appendRow([
                TextCellValue(row['name'] ?? ''),
                TextCellValue(row['department_name'] ?? ''),
                TextCellValue(row['division'] ?? ''),
                TextCellValue(exportPhaseName),
                TextCellValue('Sản phẩm Ứng dụng'),
                TextCellValue(app['event_name']?.toString() ?? ''),
                IntCellValue(app['val'] ?? 0),
                TextCellValue(app['share']?.toString() ?? ''),
                TextCellValue(app['speaker']?.toString() ?? ''),
                TextCellValue(app['coffee']?.toString() ?? ''),
                getExcelHyperlink(app['evidence_url']?.toString()),
              ]);
            }
          }
          // Bóc tách Giờ học thành từng dòng (Admin có thể xem chi tiết)
          if (row['raw_hour_dates'] != null) {
            for (var hour in (row['raw_hour_dates'] as List)) {
              if (!isItemInPeriod(hour['date'])) continue;
              sheet1.appendRow([
                TextCellValue(row['name'] ?? ''),
                TextCellValue(row['department_name'] ?? ''),
                TextCellValue(row['division'] ?? ''),
                TextCellValue(exportPhaseName),
                TextCellValue('Giờ học'),
                TextCellValue(hour['event_name']?.toString() ?? ''),
                IntCellValue(hour['val'] ?? 0),
                TextCellValue(''),
                TextCellValue(''),
                TextCellValue(''),
                TextCellValue(''),
              ]);
            }
          }
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

      // 4. Luu file Excel tren Web
      final fileBytes = excel.encode();

      if (fileBytes == null || fileBytes.isEmpty) {
        throw Exception('Không tạo được dữ liệu Excel.');
      }

      await FilePicker.saveFile(
        dialogTitle: 'Lưu báo cáo Excel',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: ['xlsx'],
        bytes: Uint8List.fromList(fileBytes),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Xuất Excel thành công!'),
            backgroundColor: Colors.green,
          ),
        );
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
    // BƯỚC 1: KIỂM TRA XEM KHÓA HỌC NÀY ĐÃ CÓ ỨNG DỤNG ĐI KÈM CHƯA
    setState(() => _isLoadingHistory = true);
    List<dynamic> linkedApps = [];
    try {
      linkedApps = await Supabase.instance.client
          .from('practical_applications')
          .select('id, created_at')
          .eq('user_id', _userId)
          .eq('course_name', courseName);
    } catch (e) {
      debugPrint('Lỗi check app liên kết: $e');
    }
    setState(() => _isLoadingHistory = false);

    // BƯỚC 2: NẾU CÓ ỨNG DỤNG -> CHẶN XÓA VÀ HƯỚNG DẪN UI/UX
    if (linkedApps.isNotEmpty) {
      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.orange),
              SizedBox(width: 8),
              Text('Không thể xóa khóa học'),
            ],
          ),
          content: Text(
            'Khóa học "$courseName" hiện đang có ${linkedApps.length} bản kê khai "Sản phẩm Ứng dụng" đi kèm.\n\n'
            'Để đảm bảo tính toàn vẹn dữ liệu, vui lòng chuyển sang tab "Sản phẩm Ứng dụng" để xóa các bài ứng dụng của khóa này trước, sau đó bạn mới có thể xóa khóa học.',
            style: const TextStyle(height: 1.5),
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.pop(ctx);
                setState(
                  () => _historyMetricIndex = 1,
                ); // Tự động chuyển tab sang Ứng dụng để user xóa
              },
              child: const Text('Chuyển sang Tab Ứng dụng'),
            ),
          ],
        ),
      );
      return;
    }

    // BƯỚC 3: NẾU KHÔNG CÓ ỨNG DỤNG -> XÓA BÌNH THƯỜNG
    if (!mounted) return;
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
            content: Text('Lỗi khi xóa: $e. Hãy kiểm tra phân quyền RLS.'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // Thêm hàm xóa Ứng dụng để hỗ trợ luồng xóa ở Tab Ứng dụng
  Future<void> _deleteAppRecord(String recordId, String courseName) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Xác nhận xóa ứng dụng'),
        content: Text(
          'Bạn có chắc muốn xóa bản kê khai ứng dụng của khóa "$courseName"?\nĐiểm thưởng của bạn sẽ bị thu hồi.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Xóa', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoadingHistory = true);
    try {
      await Supabase.instance.client
          .from('practical_applications')
          .delete()
          .eq('id', recordId);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đã xóa ứng dụng thành công'),
            backgroundColor: Colors.green,
          ),
        );
        _fetchInitialData();
      }
    } catch (e) {
      setState(() => _isLoadingHistory = false);
      if (mounted) {
        // Thêm ngoặc nhọn
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi: $e'), backgroundColor: Colors.red),
        );
      } // Đóng ngoặc nhọn
    }
  }

  String _emptyRankingMessage() {
    if (_metricIndex == 0) {
      return 'Chưa có dữ liệu giờ học trong chặng/phạm vi này.';
    }
    return 'Chưa có điểm ứng dụng trong chặng/phạm vi này. Dữ liệu giờ học không được tính vào BXH điểm.';
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
                                  // --- TAB 1: GIỜ HỌC (Nhóm theo Thời gian hoàn thành - completion_date) ---
                                  Map<String, List<dynamic>> groupedItems = {};
                                  String activePeriodName = "";

                                  for (var item in _learningHistory) {
                                    // Ưu tiên completion_date (Thời gian học viên khai báo trên Quicklog), nếu null mới dùng created_at
                                    DateTime? date = DateTime.tryParse(
                                      item['completion_date'] ??
                                          item['created_at'] ??
                                          '',
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
                                            // Gắn nhãn tự động cho lịch sử
                                            final now = DateTime.now();
                                            if (now.isAfter(
                                                  sDate.subtract(
                                                    const Duration(days: 1),
                                                  ),
                                                ) &&
                                                now.isBefore(
                                                  eDate.add(
                                                    const Duration(days: 1),
                                                  ),
                                                )) {
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

                                  // Sắp xếp khóa học bên trong từng chặng: Mới nhất lên đầu
                                  groupedItems.forEach((key, list) {
                                    list.sort((a, b) {
                                      DateTime dateA =
                                          DateTime.tryParse(
                                            a['completion_date'] ??
                                                a['created_at'] ??
                                                '',
                                          ) ??
                                          DateTime(2000);
                                      DateTime dateB =
                                          DateTime.tryParse(
                                            b['completion_date'] ??
                                                b['created_at'] ??
                                                '',
                                          ) ??
                                          DateTime(2000);
                                      return dateB.compareTo(dateA); // Giảm dần
                                    });
                                  });

                                  List<String> sortedKeys = groupedItems.keys
                                      .toList();
                                  sortedKeys.sort((a, b) {
                                    if (a == activePeriodName) return -1;
                                    if (b == activePeriodName) return 1;
                                    return b.compareTo(a);
                                  });

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
                                          initiallyExpanded: isActivePeriod,
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
                                                  '${item['platform']} • Hoàn thành: ${_formatDate(item['completion_date'] ?? item['created_at'])}',
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
                            : Builder(
                                builder: (context) {
                                  // --- TAB 2: ỨNG DỤNG (Nhóm theo Tên Khóa Học) ---
                                  Map<String, List<dynamic>> groupedApps = {};
                                  for (var item in _appHistory) {
                                    String courseName =
                                        item['course_name'] ?? 'Không xác định';
                                    groupedApps
                                        .putIfAbsent(courseName, () => [])
                                        .add(item);
                                  }

                                  // Sắp xếp các ứng dụng bên trong khóa học: Mới nhất lên đầu
                                  groupedApps.forEach((key, list) {
                                    list.sort((a, b) {
                                      DateTime dateA =
                                          DateTime.tryParse(
                                            a['created_at'] ?? '',
                                          ) ??
                                          DateTime(2000);
                                      DateTime dateB =
                                          DateTime.tryParse(
                                            b['created_at'] ?? '',
                                          ) ??
                                          DateTime(2000);
                                      return dateB.compareTo(dateA);
                                    });
                                  });

                                  List<String> sortedCourseNames = groupedApps
                                      .keys
                                      .toList();
                                  // Có thể sort theo ABC tên khóa học hoặc mặc định theo thứ tự DB trả ra

                                  return ListView.builder(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    itemCount: sortedCourseNames.length,
                                    itemBuilder: (context, index) {
                                      String courseName =
                                          sortedCourseNames[index];
                                      List<dynamic> courseApps =
                                          groupedApps[courseName]!;

                                      return Theme(
                                        data: Theme.of(context).copyWith(
                                          dividerColor: Colors.transparent,
                                        ),
                                        child: ExpansionTile(
                                          initiallyExpanded:
                                              true, // Mở sẵn hết để dễ nhìn
                                          title: Text(
                                            courseName,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 15,
                                              color: Colors.black87,
                                            ),
                                          ),
                                          subtitle: Text(
                                            '${courseApps.length} bản kê khai ứng dụng',
                                          ),
                                          leading: const Icon(
                                            Icons.menu_book,
                                            color: Colors.blue,
                                          ),
                                          children: courseApps.map((item) {
                                            // UI/UX Xử lý hiển thị Bóc tách điểm cho KNS
                                            List<Widget> pointBadges = [];
                                            if (item['ai_score'] != null &&
                                                item['ai_score'] > 0) {
                                              pointBadges.add(
                                                _buildPointChip(
                                                  'AI Chấm',
                                                  item['ai_score'],
                                                  Colors.orange,
                                                ),
                                              );
                                            }
                                            if (item['is_shared_group'] ==
                                                true) {
                                              pointBadges.add(
                                                _buildPointChip(
                                                  'Share',
                                                  '✔',
                                                  Colors.green,
                                                ),
                                              );
                                            }
                                            if (item['coffee_talk_name'] !=
                                                    null &&
                                                item['coffee_talk_name']
                                                    .toString()
                                                    .isNotEmpty) {
                                              pointBadges.add(
                                                _buildPointChip(
                                                  'Coffee',
                                                  '✔',
                                                  Colors.brown,
                                                ),
                                              );
                                            }
                                            if (item['is_speaker'] == true) {
                                              pointBadges.add(
                                                _buildPointChip(
                                                  'Speaker',
                                                  '✔',
                                                  Colors.purple,
                                                ),
                                              );
                                            }

                                            return Card(
                                              margin:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 16,
                                                    vertical: 6,
                                                  ),
                                              elevation: 1,
                                              color: Colors.orange.shade50,
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                side: BorderSide(
                                                  color: Colors.orange.shade200,
                                                  width: 1,
                                                ),
                                              ),
                                              child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(12),
                                                onTap: () =>
                                                    _showAppDetailsDialog(item),
                                                child: Padding(
                                                  padding: const EdgeInsets.all(
                                                    12.0,
                                                  ),
                                                  child: Row(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    children: [
                                                      const CircleAvatar(
                                                        backgroundColor:
                                                            Colors.orange,
                                                        radius: 18,
                                                        child: Icon(
                                                          Icons.star,
                                                          color: Colors.white,
                                                          size: 18,
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Column(
                                                          crossAxisAlignment:
                                                              CrossAxisAlignment
                                                                  .start,
                                                          children: [
                                                            Text(
                                                              'Ngày nộp: ${_formatDate(item['created_at'])}',
                                                              style:
                                                                  const TextStyle(
                                                                    fontSize:
                                                                        12,
                                                                    color: Colors
                                                                        .grey,
                                                                  ),
                                                            ),
                                                            const SizedBox(
                                                              height: 6,
                                                            ),
                                                            // Hiển thị dải Badge điểm
                                                            if (pointBadges
                                                                .isNotEmpty)
                                                              Wrap(
                                                                spacing: 6,
                                                                runSpacing: 6,
                                                                children:
                                                                    pointBadges,
                                                              )
                                                            else
                                                              const Text(
                                                                'Đang xử lý...',
                                                                style: TextStyle(
                                                                  fontSize: 12,
                                                                  fontStyle:
                                                                      FontStyle
                                                                          .italic,
                                                                ),
                                                              ),
                                                          ],
                                                        ),
                                                      ),
                                                      Column(
                                                        mainAxisAlignment:
                                                            MainAxisAlignment
                                                                .center,
                                                        crossAxisAlignment:
                                                            CrossAxisAlignment
                                                                .end,
                                                        children: [
                                                          Text(
                                                            '+${item['gamification_points'] ?? 0}đ',
                                                            style:
                                                                const TextStyle(
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold,
                                                                  color: Colors
                                                                      .orange,
                                                                  fontSize: 18,
                                                                ),
                                                          ),
                                                          IconButton(
                                                            icon: const Icon(
                                                              Icons
                                                                  .delete_outline,
                                                              color: Colors
                                                                  .redAccent,
                                                              size: 20,
                                                            ),
                                                            constraints:
                                                                const BoxConstraints(),
                                                            padding:
                                                                const EdgeInsets.only(
                                                                  top: 4,
                                                                ),
                                                            onPressed: () =>
                                                                _deleteAppRecord(
                                                                  item['id']
                                                                      .toString(),
                                                                  courseName,
                                                                ),
                                                          ),
                                                        ],
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            );
                                          }).toList(),
                                        ),
                                      );
                                    },
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
                        label: Text('🔥 Xếp hạng điểm ứng dụng'),
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
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Text(
                              _emptyRankingMessage(),
                              style: const TextStyle(color: Colors.grey),
                              textAlign: TextAlign.center,
                            ),
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

  // Helper vẽ Chip điểm cho KNS
  Widget _buildPointChip(String label, dynamic value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1), // Đã sửa withOpacity
        border: Border.all(
          color: color.withValues(alpha: 0.5),
        ), // Đã sửa withOpacity
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }
}
