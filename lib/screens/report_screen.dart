import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
  String _allRoleSystemMode =
      'tsc'; // Nút Toggle chuyển Hệ thi đua (Chỉ dùng cho Role ALL)

  List<String> _scopeOptions = [
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

  // Biến phục vụ Lazy Load Bảng Xếp Hạng
  List<Map<String, dynamic>> _rankingData = [];
  int _currentOffset = 0;
  bool _hasMoreData = true;
  bool _isLoadingMore = false;
  Map<String, dynamic>? _myRankData;
  bool _isInitialPeriodSet = false; // Biến kiểm soát gán mặc định Đợt/Chặng

  // Hàm tự động tính toán danh sách Dropdown Thời gian dựa theo Role
  void _updatePeriodDropdownState() {
    List<String> fetchedPeriods = [];
    String? activePeriodName;
    final now = DateTime.now();

    for (var p in _periodsConfig) {
      // BỘ LỌC MỚI: Nếu là Role ALL, chỉ lấy các chặng thuộc hệ thi đua đang chọn (TSC hoặc KNS)
      if (_userRole == 'all' && p['target_role'] != _allRoleSystemMode) {
        continue;
      }

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

    setState(() {
      _periodOptions = ['Toàn chặng (Tích lũy)', ...fetchedPeriods];

      // Tự động trỏ bộ lọc: Ưu tiên chặng Active -> Chặng gần nhất -> Toàn chặng
      if (!_isInitialPeriodSet) {
        // Lần đầu tải app: Ép thẳng vào Đợt/Chặng đang Active
        _selectedPeriod =
            activePeriodName ??
            (fetchedPeriods.isNotEmpty
                ? fetchedPeriods.last
                : 'Toàn chặng (Tích lũy)');
        _isInitialPeriodSet = true;
      } else if (!_periodOptions.contains(_selectedPeriod)) {
        // Khi đổi Hệ thi đua (TSC <-> KNS), chặng cũ không còn thì gán lại chặng Active
        _selectedPeriod =
            activePeriodName ??
            (fetchedPeriods.isNotEmpty
                ? fetchedPeriods.last
                : 'Toàn chặng (Tích lũy)');
      }
    });
  }

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

        // Xử lý bộ lọc phạm vi cho KNS (Không có Toàn hệ thống, mặc định xem của Phòng)
        if (_userRole == 'kns' && !_isAdmin) {
          _scopeOptions = ['Khối của tôi', 'Phòng của tôi'];
          _selectedScope = 'Phòng của tôi';
        }

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

      // (Đã xóa đoạn tải gamification_rules vì logic tính điểm chuẩn hóa KNS/TSC đã được chuyển lên xử lý trực tiếp tại hàm RPC trên Supabase Server)

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

      // 3. Bỏ qua tải data khổng lồ ban đầu để tránh tốn API
      // Data sẽ chỉ được tải khi bấm nút Xuất báo cáo (Lazy Load)

      if (mounted) {
        _updatePeriodDropdownState(); // Gọi hàm cập nhật danh sách đợt/chặng theo Hệ Thi Đua
        setState(() {
          _isLoading = false;
        });
        _processRanking(); // Gọi RPC để lấy đúng BXH hiển thị
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
    // 1. Phân tích loại hoạt động KNS
    bool isShare = item['is_shared_group'] == true;
    bool isSpeaker = item['is_speaker'] == true;
    String? coffeeName = item['coffee_talk_name']?.toString();
    bool isCoffee = coffeeName != null && coffeeName.trim().isNotEmpty;

    // 2. Phân tích nội dung text ứng dụng tiêu chuẩn
    String? keyLearnings = item['key_learnings']?.toString();
    String? practicalResults = item['practical_results']?.toString();
    bool hasStandardApp =
        (keyLearnings != null && keyLearnings.trim().isNotEmpty) ||
        (practicalResults != null && practicalResults.trim().isNotEmpty);

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
              // --- PHẦN 1: HOẠT ĐỘNG KNS ĐẶC THÙ ---
              if (isShare || isSpeaker || isCoffee) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.orange.shade200),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Các hoạt động KNS đã ghi nhận:',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.orange,
                        ),
                      ),
                      const SizedBox(height: 8),
                      if (isShare)
                        const Row(
                          children: [
                            Icon(
                              Icons.check_circle,
                              color: Colors.green,
                              size: 16,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'Chia sẻ nhóm (Share Group)',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      if (isCoffee)
                        Padding(
                          padding: EdgeInsets.only(top: isShare ? 6.0 : 0),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Icon(
                                Icons.coffee,
                                color: Colors.brown,
                                size: 16,
                              ),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Đào tạo Coffee Talk:\n$coffeeName',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (isSpeaker)
                        Padding(
                          padding: EdgeInsets.only(
                            top: (isShare || isCoffee) ? 6.0 : 0,
                          ),
                          child: const Row(
                            children: [
                              Icon(Icons.mic, color: Colors.purple, size: 16),
                              SizedBox(width: 6),
                              Text(
                                'Đứng lớp Diễn giả (Speaker)',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ],

              // --- PHẦN 2: NỘI DUNG ỨNG DỤNG TIÊU CHUẨN ---
              if (hasStandardApp) ...[
                const Text(
                  'Kiến thức tâm đắc:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  keyLearnings ?? 'Không có dữ liệu',
                  style: const TextStyle(color: Colors.black87, fontSize: 13),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Thực tế áp dụng:',
                  style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  practicalResults ?? 'Không có dữ liệu',
                  style: const TextStyle(color: Colors.black87, fontSize: 13),
                ),
              ] else if (!isShare && !isSpeaker && !isCoffee) ...[
                // Fallback nếu bài này rỗng hoàn toàn (Chống blank UI)
                const Text(
                  'Bản kê khai này chưa có nội dung chi tiết.',
                  style: TextStyle(
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                ),
              ],

              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12.0),
                child: Divider(height: 1, thickness: 1),
              ),

              // --- PHẦN 3: ĐIỂM & ĐÁNH GIÁ AI ---
              Row(
                children: [
                  const Icon(Icons.stars, color: Colors.orange, size: 22),
                  const SizedBox(width: 8),
                  Text(
                    'Tổng điểm đạt được: ${item['gamification_points'] ?? 0} điểm',
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

  // Hàm tải toàn bộ dữ liệu thô (CHỈ CHẠY KHI ADMIN/ĐẦU MỐI BẤM NÚT TẢI BÁO CÁO)
  Future<void> _prepareDataForExport(List<dynamic> allPeriodsConfig) async {
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
            'evidence_url': ev['evidence_url'],
          });
        }
      }
    }

    _allRawData = userStats.values.toList();
    _allRawData.add({'config_helper': allPeriodsConfig});
  }

  // Tải BXH từ Database bằng RPC với Pagination (Chỉ tải những ai cần xem)
  Future<void> _processRanking({bool isLoadMore = false}) async {
    if (_userId.isEmpty) return;

    if (!isLoadMore) {
      _currentOffset = 0;
      _hasMoreData = true;
      if (mounted) setState(() => _rankingData.clear());
    } else {
      if (mounted) setState(() => _isLoadingMore = true);
    }

    String searchPeriodName = _selectedPeriod;
    // SỬA LỖI: Bỏ qua cắt chuỗi nếu đang chọn 'Toàn chặng (Tích lũy)' để Database không bị tìm sai tên đợt
    if (searchPeriodName != 'Toàn chặng (Tích lũy)' &&
        searchPeriodName.contains(' (')) {
      searchPeriodName = searchPeriodName
          .substring(0, searchPeriodName.indexOf(' ('))
          .trim();
    }

    try {
      int limit = isLoadMore ? 10 : 5;

      final res = await Supabase.instance.client.rpc(
        'get_smart_leaderboard',
        params: {
          'p_period': searchPeriodName,
          'p_scope': _selectedScope,
          'p_role_mode': _userRole == 'all' ? _allRoleSystemMode : _userRole,
          'p_division': _userDivision,
          'p_dept_id': _userDeptId ?? 0,
          'p_metric': _metricIndex,
          'p_limit': limit,
          'p_offset': _currentOffset,
          'p_req_user_id': _userId,
        },
      );

      final List<dynamic> fetchedData = res as List<dynamic>;

      if (mounted) {
        setState(() {
          if (isLoadMore) {
            // Thêm data mới và lọc trùng lặp (vì người tải thêm có thể đã xuất hiện trong cụm Hàng xóm)
            for (var item in fetchedData) {
              if (!_rankingData.any(
                (existing) => existing['id'] == item['id'],
              )) {
                _rankingData.add(item as Map<String, dynamic>);
              }
            }
            _isLoadingMore = false;
            if (fetchedData.length < limit) _hasMoreData = false;
            _currentOffset += limit;
          } else {
            _rankingData = List<Map<String, dynamic>>.from(fetchedData);
            // Cập nhật thẻ Sticky "Thành tích của Bạn" ở dưới cùng màn hình
            int myIndex = _rankingData.indexWhere((u) => u['id'] == _userId);
            _myRankData = myIndex != -1 ? _rankingData[myIndex] : null;

            _currentOffset = limit;
            if (fetchedData.length < limit) _hasMoreData = false;
          }
          // Sắp xếp lại danh sách theo thứ tự hạng để UI chèn Gap mượt mà
          _rankingData.sort(
            (a, b) => (a['rank'] as int).compareTo(b['rank'] as int),
          );
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải BXH từ Database: $e');
      if (mounted) setState(() => _isLoadingMore = false);
    }
  }

  Future<void> _exportData({
    Map<String, dynamic>? specificUser,
    bool isHRReport = true,
  }) async {
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
      // BẮT ĐẦU TẢI DỮ LIỆU THÔ KHI BẤM NÚT XUẤT (Lazy Loading)
      if (_allRawData.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Đang trích xuất dữ liệu từ máy chủ, vui lòng đợi...',
              ),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 4),
            ),
          );
        }
        await _prepareDataForExport(_periodsConfig);
      }

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
          exportList = allUsers.where((u) => u['role'] == 'kns').toList();
          fileName = "BaoCao_KhoiNS_$timestamp.xlsx";
        } else {
          exportList = allUsers.where((u) => u['role'] == 'tsc').toList();
          fileName = "BaoCao_TSC_$timestamp.xlsx";
        }
      } else {
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

      // --- TẠO CÁC SHEET MỚI ---
      Sheet sheet1 = excel['Báo Cáo Tổng Hợp'];
      Sheet sheet2 = excel['Chi tiết Giờ học'];
      Sheet sheet3 = excel['Chi tiết Ứng dụng'];
      excel.delete('Sheet1'); // Xóa sheet mặc định

      String exportPhaseName = _selectedPeriod.replaceAll(' (Đang Active)', '');

      // HEADER SHEET 1 (Giữ nguyên cấu trúc báo cáo cũ)
      List<CellValue> header1;
      if (isHRReport) {
        header1 = [
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
        header1 = [
          TextCellValue('Họ và tên'),
          TextCellValue('Phòng ban'),
          TextCellValue('Khối'),
          TextCellValue('Chặng/Đợt'),
          TextCellValue('Tổng Giờ học'),
          TextCellValue('Tổng Số SP'),
          TextCellValue('Tổng Điểm'),
        ];
      }
      sheet1.appendRow(header1);

      // HEADER SHEET 2 (Chi tiết giờ học)
      sheet2.appendRow([
        TextCellValue('Đơn vị'),
        TextCellValue('Họ và tên'),
        TextCellValue('Tên khóa học'),
        TextCellValue('Thời gian kê khai (theo đợt)'),
        TextCellValue('Số giờ học tập'),
        TextCellValue('Link minh chứng'),
      ]);

      // HEADER SHEET 3 (Chi tiết kết quả ứng dụng)
      sheet3.appendRow([
        TextCellValue('Đơn vị'),
        TextCellValue('Họ và tên'),
        TextCellValue('Tên khóa học'),
        TextCellValue('Thời gian ứng dụng (theo đợt)'),
        TextCellValue('Kiến thức tâm đắc'),
        TextCellValue('Kết quả ứng dụng'),
        TextCellValue('Link đính kèm'),
        TextCellValue('File minh chứng đính kèm'),
      ]);

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

      // SỬA LỖI BLANK MINH CHỨNG: Encode khoảng trắng và cho phép truyền custom text
      CellValue getExcelHyperlink(String? rawPaths, {String? customText}) {
        if (rawPaths == null || rawPaths.trim().isEmpty) {
          return TextCellValue('');
        }
        final String bucketName = 'learning-evidence';
        List<String> paths = rawPaths.split(';');
        String firstPath = paths.first.trim();
        if (firstPath.isEmpty) {
          return TextCellValue('');
        }

        String publicUrl = Supabase.instance.client.storage
            .from(bucketName)
            .getPublicUrl(firstPath);
        publicUrl = Uri.encodeFull(
          publicUrl,
        ); // Quan trọng: Tránh lỗi file tải về bị Blank trên Windows

        String linkText =
            customText ??
            (paths.length > 1
                ? 'Xem Minh Chứng (+${paths.length - 1} file)'
                : 'Xem Minh Chứng');
        return FormulaCellValue('HYPERLINK("$publicUrl", "$linkText")');
      }

      // --- TRUY VẤN DỮ LIỆU CHI TIẾT TỪ BẢNG GỐC CHO SHEET 2 & 3 ---
      List<String> userIds = exportList.map((u) => u['id'].toString()).toList();
      List<dynamic> detailHours = [];
      List<dynamic> detailApps = [];
      List<dynamic> listAttachments = [];

      if (userIds.isNotEmpty) {
        try {
          detailHours = await Supabase.instance.client
              .from('learning_hours')
              .select(
                'id, user_id, course_name, completion_date, created_at, duration_minutes',
              )
              .inFilter('user_id', userIds);

          detailApps = await Supabase.instance.client
              .from('practical_applications')
              .select(
                'id, user_id, course_name, created_at, key_learnings, practical_results, evidence_url',
              )
              .inFilter('user_id', userIds);

          listAttachments = await Supabase.instance.client
              .from('evidence_attachments')
              .select('record_id, file_path, file_name');
        } catch (e) {
          debugPrint("Lỗi tải data chi tiết từ bảng gốc: $e");
        }
      }

      // Nhóm dữ liệu để dễ mapping khi lặp danh sách cán bộ
      Map<String, List<dynamic>> mapHours = {};
      for (var h in detailHours) {
        mapHours.putIfAbsent(h['user_id'].toString(), () => []).add(h);
      }

      Map<String, List<dynamic>> mapApps = {};
      for (var a in detailApps) {
        mapApps.putIfAbsent(a['user_id'].toString(), () => []).add(a);
      }

      Map<String, dynamic> mapAtt = {};
      for (var att in listAttachments) {
        mapAtt[att['record_id'].toString()] = att;
      }

      // --- TIẾN HÀNH ĐỔ DỮ LIỆU VÀO CÁC SHEET ---
      for (var row in exportList) {
        String uid = row['id'].toString();
        String dept = row['department_name'] ?? '';
        String name = row['name'] ?? '';

        // ĐỔ DATA SHEET 1
        if (isHRReport) {
          if (row['raw_app_dates'] != null) {
            for (var app in (row['raw_app_dates'] as List)) {
              if (!isItemInPeriod(app['date'])) continue;
              sheet1.appendRow([
                TextCellValue(name),
                TextCellValue(dept),
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
          if (row['raw_hour_dates'] != null) {
            for (var hour in (row['raw_hour_dates'] as List)) {
              if (!isItemInPeriod(hour['date'])) continue;
              sheet1.appendRow([
                TextCellValue(name),
                TextCellValue(dept),
                TextCellValue(row['division'] ?? ''),
                TextCellValue(exportPhaseName),
                TextCellValue('Giờ học'),
                TextCellValue(hour['event_name']?.toString() ?? ''),
                IntCellValue(hour['val'] ?? 0),
                TextCellValue(''),
                TextCellValue(''),
                TextCellValue(''),
                getExcelHyperlink(hour['evidence_url']?.toString()),
              ]);
            }
          }
        } else {
          sheet1.appendRow([
            TextCellValue(name),
            TextCellValue(dept),
            TextCellValue(row['division'] ?? ''),
            TextCellValue(exportPhaseName),
            IntCellValue(row['sort_hours'] ?? row['total_hours'] ?? 0),
            IntCellValue(row['products'] ?? 0),
            IntCellValue(row['sort_points'] ?? row['total_points'] ?? 0),
          ]);
        }

        // ĐỔ DATA SHEET 2 (Chi tiết giờ học)
        if (mapHours.containsKey(uid)) {
          for (var h in mapHours[uid]!) {
            DateTime? hDate = DateTime.tryParse(
              h['completion_date'] ?? h['created_at'] ?? '',
            );
            if (!isItemInPeriod(hDate)) continue;

            String hId = h['id'].toString();
            var attInfo = mapAtt[hId];
            String evidencePath = attInfo != null ? attInfo['file_path'] : '';

            sheet2.appendRow([
              TextCellValue(dept),
              TextCellValue(name),
              TextCellValue(h['course_name']?.toString() ?? ''),
              TextCellValue(
                hDate != null
                    ? '${hDate.day}/${hDate.month}/${hDate.year}'
                    : '',
              ),
              IntCellValue((h['duration_minutes'] as num?)?.toInt() ?? 0),
              getExcelHyperlink(evidencePath, customText: 'Xem Minh Chứng'),
            ]);
          }
        }

        // ĐỔ DATA SHEET 3 (Chi tiết kết quả ứng dụng)
        if (mapApps.containsKey(uid)) {
          for (var a in mapApps[uid]!) {
            DateTime? aDate = DateTime.tryParse(a['created_at'] ?? '');
            if (!isItemInPeriod(aDate)) continue;

            String appId = a['id'].toString();
            var attInfo = mapAtt[appId];
            String evidencePath =
                a['evidence_url']?.toString() ??
                (attInfo != null ? attInfo['file_path'] : '');
            String fileNameAtt = attInfo != null
                ? attInfo['file_name']?.toString() ?? 'Tải file'
                : 'Xem Minh Chứng';

            sheet3.appendRow([
              TextCellValue(dept),
              TextCellValue(name),
              TextCellValue(a['course_name']?.toString() ?? ''),
              TextCellValue(
                aDate != null
                    ? '${aDate.day}/${aDate.month}/${aDate.year}'
                    : '',
              ),
              TextCellValue(a['key_learnings']?.toString() ?? ''),
              TextCellValue(a['practical_results']?.toString() ?? ''),
              getExcelHyperlink(
                evidencePath,
                customText: 'Mở Link',
              ), // Cột Link Đính kèm
              getExcelHyperlink(
                evidencePath,
                customText: fileNameAtt,
              ), // Cột Minh chứng đính kèm hiển thị tên file
            ]);
          }
        }
      }

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

  Future<void> _editLearningRecord(
    Map<String, dynamic> item,
    String currentPeriod,
  ) async {
    // Tìm chặng/đợt tương ứng để kiểm tra cutoff date
    Map<String, dynamic>? matchedPeriod;
    for (var p in _periodsConfig) {
      if (p['period_name'] == currentPeriod ||
          '${p['period_name']} (Đang Active)' == currentPeriod) {
        matchedPeriod = p;
        break;
      }
    }

    if (matchedPeriod != null && matchedPeriod['claim_cutoff_date'] != null) {
      try {
        DateTime cutoff = DateTime.parse(
          matchedPeriod['claim_cutoff_date'],
        ).toLocal();
        // Cho phép sửa đến hết ngày cutoff (23:59:59)
        cutoff = DateTime(cutoff.year, cutoff.month, cutoff.day, 23, 59, 59);
        if (DateTime.now().isAfter(cutoff)) {
          if (!mounted) return;
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Row(
                children: [
                  Icon(Icons.lock_clock, color: Colors.orange),
                  SizedBox(width: 8),
                  Text('Đã hết hạn sửa'),
                ],
              ),
              content: const Text(
                'Chặng thi đua này đã vượt quá thời gian gia hạn (Cut-off date) của Admin. Bạn không thể sửa thời gian học nữa.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Đóng'),
                ),
              ],
            ),
          );
          return;
        }
      } catch (e) {
        debugPrint('Lỗi parse cutoff date: $e');
      }
    }

    final TextEditingController timeController = TextEditingController(
      text: item['duration_minutes'].toString(),
    );
    final formKey = GlobalKey<FormState>();

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Sửa thời gian học'),
        content: Form(
          key: formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Khóa học: ${item['course_name']}',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: timeController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Thời gian học (phút)',
                  border: OutlineInputBorder(),
                  suffixText: 'phút',
                ),
                validator: (val) {
                  if (val == null || val.trim().isEmpty) {
                    return 'Vui lòng nhập số phút';
                  }
                  final numVal = int.tryParse(val.trim());
                  if (numVal == null || numVal <= 0) {
                    return 'Số phút phải > 0';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Hủy', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            onPressed: () {
              if (formKey.currentState!.validate()) {
                Navigator.pop(ctx, true);
              }
            },
            child: const Text('Lưu thay đổi'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    setState(() => _isLoadingHistory = true);
    try {
      final newTime = int.parse(timeController.text.trim());
      await Supabase.instance.client
          .from('learning_hours')
          .update({'duration_minutes': newTime})
          .eq('id', item['id']);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cập nhật thời gian học thành công'),
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
            content: Text('Lỗi khi cập nhật: $e'),
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
                                                        Icons.edit_outlined,
                                                        color:
                                                            Colors.blueAccent,
                                                        size: 22,
                                                      ),
                                                      tooltip: 'Sửa thời gian',
                                                      onPressed: () =>
                                                          _editLearningRecord(
                                                            item,
                                                            currentPeriod,
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
                // [UI/UX] Chỉ hiển thị Segmented Button chọn Hệ Thi đua cho Role ALL
                if (_userRole == 'all')
                  Container(
                    color: Colors.white,
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    width: double.infinity,
                    child: SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(
                          value: 'tsc',
                          label: Text('Thi đua TSC'),
                          icon: Icon(Icons.account_balance, size: 18),
                        ),
                        ButtonSegment(
                          value: 'kns',
                          label: Text('Thi đua KNS'),
                          icon: Icon(Icons.groups, size: 18),
                        ),
                      ],
                      selected: {_allRoleSystemMode},
                      onSelectionChanged: (Set<String> newSelection) {
                        setState(() {
                          _allRoleSystemMode = newSelection.first;

                          // Cập nhật lại bộ lọc Phạm vi dựa theo Hệ thi đua
                          if (_allRoleSystemMode == 'kns') {
                            _scopeOptions = ['Khối của tôi', 'Phòng của tôi'];
                            if (_selectedScope == 'Toàn hệ thống') {
                              _selectedScope =
                                  'Khối của tôi'; // Đẩy về mặc định hợp lệ
                            }
                          } else {
                            _scopeOptions = [
                              'Toàn hệ thống',
                              'Khối của tôi',
                              'Phòng của tôi',
                            ];
                          }
                        });
                        _updatePeriodDropdownState(); // Reset Dropdown theo Hệ vừa chọn
                        _processRanking(); // Tải lại BXH
                      },
                      style: ButtonStyle(
                        backgroundColor: WidgetStateProperty.resolveWith<Color>(
                          (states) {
                            if (states.contains(WidgetState.selected)) {
                              return _allRoleSystemMode == 'tsc'
                                  ? Colors.blue.shade50
                                  : Colors.orange.shade50;
                            }
                            return Colors.transparent;
                          },
                        ),
                        iconColor: WidgetStateProperty.resolveWith<Color>((
                          states,
                        ) {
                          if (states.contains(WidgetState.selected)) {
                            return _allRoleSystemMode == 'tsc'
                                ? Colors.blue.shade700
                                : Colors.orange.shade700;
                          }
                          return Colors.grey;
                        }),
                      ),
                    ),
                  ),
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
                  child: _rankingData.isEmpty
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
                      : _buildSmartLeaderboardList(),
                ),
                // Sticky Card "Thành tích của Bạn"
                // TỐI ƯU UX: Chỉ hiện thanh dính đáy nếu user chưa có thành tích (null)
                // HOẶC hạng của họ lớn hơn số lượng Top đang hiển thị trên màn hình (_currentOffset).
                if (_myRankData == null ||
                    (_myRankData!['rank'] as num).toInt() > _currentOffset)
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
                            _myRankData != null
                                ? '${_myRankData!['rank']}'
                                : '-',
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
                          _metricIndex == 0
                              ? (_myRankData != null
                                    ? '${(_myRankData!['sort_hours'] ?? 0) ~/ 60} giờ ${(_myRankData!['sort_hours'] ?? 0) % 60} phút'
                                    : '0 phút')
                              : '${_myRankData != null ? _myRankData!['sort_points'] : 0} điểm',
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

  // Render Bảng xếp hạng thông minh có Gap (...) và nút Tải thêm
  Widget _buildSmartLeaderboardList() {
    List<Widget> items = [];

    for (int i = 0; i < _rankingData.length; i++) {
      final user = _rankingData[i];
      final isMe = user['id'] == _userId;
      final int rank = user['rank'] ?? 0;

      // UX XỊN: Xử lý vẽ khoảng trống (...) nếu hạng bị nhảy cóc
      if (i > 0) {
        int prevRank = _rankingData[i - 1]['rank'] ?? 0;
        if (rank > prevRank + 1) {
          items.add(
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  const Expanded(child: Divider()),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      '... ${rank - prevRank - 1} đồng nghiệp ...',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                  const Expanded(child: Divider()),
                ],
              ),
            ),
          );
        }
      }

      // Vẽ thẻ User
      items.add(
        Card(
          elevation: isMe ? 4 : 1,
          color: isMe ? Colors.amber.shade50 : Colors.white,
          margin: const EdgeInsets.symmetric(vertical: 4),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: isMe ? Colors.amber : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: rank == 1
                  ? Colors.amber
                  : (rank == 2
                        ? Colors.grey.shade400
                        : (rank == 3
                              ? Colors.brown.shade300
                              : Colors.blue.shade50)),
              child: Text(
                '$rank',
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: rank <= 3 ? Colors.white : Colors.blue.shade900,
                ),
              ),
            ),
            title: Text(
              user['name'] ?? 'Ẩn danh',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: isMe ? Colors.amber.shade900 : Colors.black87,
              ),
            ),
            subtitle: Text(
              [user['department_name'], user['division']]
                  .where((e) => e != null && e.toString().trim().isNotEmpty)
                  .join(' - '),
              style: const TextStyle(fontSize: 12),
            ),
            trailing: Text(
              _metricIndex == 0
                  ? '${(user['sort_hours'] ?? 0) ~/ 60} giờ ${(user['sort_hours'] ?? 0) % 60} phút'
                  : '${user['sort_points'] ?? 0} điểm',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
                color: _metricIndex == 0
                    ? Colors.green.shade700
                    : Colors.blue.shade700,
              ),
            ),
          ),
        ),
      );
    }

    // Vẽ nút Tải thêm ở cuối cùng nếu chưa cạn kiệt Data
    if (_hasMoreData) {
      items.add(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Center(
            child: _isLoadingMore
                ? const CircularProgressIndicator()
                : OutlinedButton.icon(
                    onPressed: () => _processRanking(isLoadMore: true),
                    icon: const Icon(Icons.expand_more),
                    label: const Text('Xem thêm 10 hạng tiếp theo'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.blue.shade700,
                      side: BorderSide(color: Colors.blue.shade200),
                    ),
                  ),
          ),
        ),
      );
    }

    return ListView(padding: const EdgeInsets.all(12), children: items);
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
