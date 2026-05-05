import 'dart:async'; // Bắt buộc để sử dụng Timer
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';
import 'quick_log_widget.dart';
import 'history_screen.dart';
import 'admin_setup_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Trạng thái lưu thông tin người dùng
  String _fullName = 'Đang tải...';
  String _division = 'Đang tải...';
  String _department = ''; // Thêm biến lưu tên phòng ban
  bool _isKNS = false;
  bool _isAllRole = false; // Vai trò lai Phòng B
  bool _isAdmin = false; // Biến kiểm tra phân quyền Admin
  String? _avatarUrl; // Link ảnh Avatar
  String _activePeriodName = 'Đợt hiện tại';
  List<Map<String, dynamic>> _availablePeriods = []; // Danh sách chặng để lọc
  Map<String, dynamic>?
  _selectedFilterPeriod; // Chặng đang được người dùng chọn lọc

  // Trạng thái hiển thị số liệu tổng quan
  int _totalHours = 0;
  int _totalPoints = 0;
  int _totalProducts = 0;
  int _totalAiPts = 0; // Thêm biến lưu điểm AI

  // Trạng thái xếp hạng cá nhân
  String? _departmentId;
  int _rankHoursDept = 0, _rankHoursDiv = 0, _rankHoursSys = 0;
  int _rankPointsDept = 0, _rankPointsDiv = 0, _rankPointsSys = 0;

  // Render động hoàn toàn các thẻ KNS (Không fix cứng biến)
  List<Map<String, dynamic>> _knsDynamicCards = [];

  // Hàm hiển thị Popup nhập Báo lỗi và Gửi Mail ngầm
  void _showReportIssueDialog() {
    final TextEditingController contentController = TextEditingController();
    bool isSending = false;
    int countdown = 10;
    Timer? sendTimer;

    showDialog(
      context: context,
      barrierDismissible: false, // Chặn bấm ra ngoài để tắt
      builder: (ctx) {
        return PopScope(
          canPop: !isSending, // Khóa nút Back của điện thoại khi đang gửi
          child: StatefulBuilder(
            builder: (contextDialog, setStateDialog) {
              return AlertDialog(
                title: const Row(
                  children: [
                    Icon(Icons.bug_report, color: Colors.orange),
                    SizedBox(width: 8),
                    Text(
                      'Báo lỗi / Góp ý',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                content: SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Nội dung sẽ được gửi trực tiếp đến hệ thống để xử lý.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: contentController,
                        maxLines: 5,
                        enabled: !isSending,
                        decoration: const InputDecoration(
                          hintText:
                              'Mô tả chi tiết lỗi bạn gặp phải hoặc góp ý...',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      const SizedBox(height: 8),
                      // Dòng text chuyên nghiệp theo yêu cầu
                      const Text(
                        'Sản phẩm được phát triển bởi Trường ĐT&PTNNL.\nMọi vướng mắc, vui lòng liên hệ trực tiếp qua email: hapt12@vietinbank.vn',
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: Colors.blueGrey,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: isSending ? null : () => Navigator.pop(ctx),
                    child: const Text(
                      'Hủy',
                      style: TextStyle(color: Colors.grey),
                    ),
                  ),
                  ElevatedButton(
                    onPressed: isSending
                        ? null
                        : () async {
                            final content = contentController.text.trim();
                            if (content.isEmpty) {
                              ScaffoldMessenger.of(ctx).showSnackBar(
                                const SnackBar(
                                  content: Text('Vui lòng nhập nội dung!'),
                                ),
                              );
                              return;
                            }

                            setStateDialog(() {
                              isSending = true;
                              countdown = 10;
                            });

                            sendTimer = Timer.periodic(
                              const Duration(seconds: 1),
                              (timer) {
                                if (mounted) {
                                  setStateDialog(() {
                                    if (countdown > 0) countdown--;
                                  });
                                }
                              },
                            );

                            // BẢO VỆ ASYNC GAP: Lưu context trước khi chạy lệnh await
                            final navigator = Navigator.of(ctx);
                            final messenger = ScaffoldMessenger.of(context);

                            try {
                              // Truy vấn Database để lấy toàn bộ email của các Admin
                              final adminRes = await Supabase.instance.client
                                  .from('profiles')
                                  .select('email')
                                  .eq('is_admin', true);

                              List<String> adminEmails = [];
                              for (var row in adminRes) {
                                if (row['email'] != null &&
                                    row['email'].toString().trim().isNotEmpty) {
                                  adminEmails.add(row['email']);
                                }
                              }

                              // Dự phòng: Nếu Database lỗi hoặc chưa có ai là admin thì gửi về email mặc định
                              if (adminEmails.isEmpty) {
                                adminEmails.add('hapt12@vietinbank.vn');
                              }

                              // Thông tin tài khoản trạm gửi đi (Lấy từ bảng system_configs)
                              String username = '';
                              String appPassword = '';

                              final smtpConfigRes = await Supabase
                                  .instance
                                  .client
                                  .from('system_configs')
                                  .select('config_key, config_value')
                                  .inFilter('config_key', [
                                    'smtp_username',
                                    'smtp_password',
                                  ]);

                              for (var row in smtpConfigRes) {
                                if (row['config_key'] == 'smtp_username') {
                                  username =
                                      row['config_value']?.toString() ?? '';
                                }
                                if (row['config_key'] == 'smtp_password') {
                                  appPassword =
                                      row['config_value']?.toString() ?? '';
                                }
                              }

                              if (username.isEmpty || appPassword.isEmpty) {
                                throw Exception(
                                  'Chưa cấu hình tài khoản Email gửi đi (smtp_username / smtp_password) trong hệ thống!',
                                );
                              }
                              final smtpServer = gmail(username, appPassword);
                              final currentUserId =
                                  Supabase
                                      .instance
                                      .client
                                      .auth
                                      .currentUser
                                      ?.id ??
                                  'Khách';

                              final message = Message()
                                ..from = Address(
                                  username,
                                  'Hệ thống Tôi Tự Học',
                                )
                                ..recipients.addAll(adminEmails)
                                ..subject =
                                    'Báo cáo sự cố / Góp ý từ $_fullName'
                                ..text =
                                    '''
Xin chào,

Hệ thống vừa nhận được một Báo cáo / Góp ý từ người dùng trên App:

--- THÔNG TIN NGƯỜI GỬI ---
- Họ và tên: $_fullName
- Đơn vị: ${_department.isNotEmpty ? '$_division - $_department' : _division}
- User ID: $currentUserId
- Thời gian: ${DateTime.now().toLocal()}
---------------------------

--- NỘI DUNG CHI TIẾT ---
$content
''';

                              await send(message, smtpServer);

                              sendTimer?.cancel();
                              if (!mounted) return;

                              navigator.pop();
                              messenger.showSnackBar(
                                const SnackBar(
                                  content: Text('Đã gửi báo cáo thành công!'),
                                  backgroundColor: Colors.green,
                                ),
                              );
                            } catch (e) {
                              sendTimer?.cancel();
                              setStateDialog(() => isSending = false);
                              if (!mounted) return;

                              messenger.showSnackBar(
                                SnackBar(
                                  content: Text('Lỗi gửi báo cáo: $e'),
                                  backgroundColor: Colors.red,
                                  duration: const Duration(seconds: 5),
                                ),
                              );
                            }
                          },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade800,
                    ),
                    child: isSending
                        ? Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                countdown > 0
                                    ? 'Đang gửi... (${countdown}s)'
                                    : 'Đang xử lý...',
                                style: const TextStyle(color: Colors.white),
                              ),
                            ],
                          )
                        : const Text(
                            'Gửi báo cáo',
                            style: TextStyle(color: Colors.white),
                          ),
                  ),
                ],
              );
            },
          ),
        );
      },
    ).then((_) {
      sendTimer?.cancel();
    });
  }

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    await _fetchUserProfile();
    await _fetchLearningStats(); // Tải số liệu sau khi đã biết chính xác role người dùng
  }

  // Hàm lấy tổng giờ học và điểm ứng dụng theo cấu hình Đợt hiện tại
  Future<void> _fetchLearningStats() async {
    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) return;

      // 1. Tải danh sách chặng và LỌC chuẩn hóa theo mốc thời gian
      var query = Supabase.instance.client
          .from('learning_periods')
          .select('period_name, start_date, end_date, target_role');

      if (_isAllRole) {
        query = query.inFilter('target_role', ['tsc', 'kns']);
      } else {
        query = query.eq('target_role', _isKNS ? 'kns' : 'tsc');
      }
      final periodsRes = await query.order('start_date', ascending: true);

      final now = DateTime.now();
      List<Map<String, dynamic>> validPeriods = [];

      for (var p in periodsRes) {
        // Tự động format tên chặng kèm thời gian thực tế từ DB
        Map<String, dynamic> period = Map<String, dynamic>.from(p);
        String rawName = period['period_name'] ?? '';
        // Cắt bỏ phần text (ngày/tháng) cũ nếu Admin có lỡ nhập tay
        String baseName = rawName.replaceAll(RegExp(r'\s*\(.*?\)'), '').trim();

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

        validPeriods.add(period); // Luôn nạp chặng vào danh sách

        // Logic chặn Dropdown: Nếu ngày kết thúc của chặng này từ hôm nay trở đi
        // (nghĩa là chặng này đang diễn ra), thì lập tức DỪNG vòng lặp, không hiển thị các chặng sau.
        if (eDate != null && now.isBefore(eDate.add(const Duration(days: 1)))) {
          break;
        }
      }

      Map<String, dynamic>? activePeriod;
      if (_selectedFilterPeriod != null) {
        activePeriod = _selectedFilterPeriod; // Ưu tiên chặng user chọn
      } else if (validPeriods.isNotEmpty) {
        // Mặc định luôn trỏ về chặng cuối cùng trong danh sách hợp lệ vừa lọc được
        activePeriod = validPeriods.last;
        _selectedFilterPeriod = activePeriod;
      }

      DateTime? sDate;
      DateTime? eDate;
      if (activePeriod != null) {
        sDate = DateTime.tryParse(activePeriod['start_date'] ?? '');
        eDate = DateTime.tryParse(activePeriod['end_date'] ?? '');
        if (mounted) {
          setState(() {
            _availablePeriods = validPeriods;
            _activePeriodName = activePeriod!['period_name'];
          });
        }
      } else {
        // Trường hợp chưa có chặng nào đến thời gian bắt đầu
        if (mounted) {
          setState(() {
            _availablePeriods = [];
            _activePeriodName = 'Chưa đến thời gian ghi nhận';
            _totalHours = 0;
            _totalPoints = 0;
            _totalProducts = 0;
            _knsDynamicCards = [];
          });
        }
        return;
      }

      // 2. Tính tổng giờ học
      final hoursResponse = await Supabase.instance.client
          .from('learning_hours')
          // Ưu tiên dùng completion_date mới tạo, nếu data cũ bị null thì lùi về created_at
          .select('duration_minutes, created_at, completion_date')
          .eq('user_id', userId);

      int totalMins = 0;
      for (var row in hoursResponse) {
        DateTime? recordDate = DateTime.tryParse(
          row['completion_date'] ?? row['created_at'] ?? '',
        );
        if (recordDate != null && sDate != null && eDate != null) {
          if (recordDate.isAfter(sDate.subtract(const Duration(days: 1))) &&
              recordDate.isBefore(eDate.add(const Duration(days: 1)))) {
            totalMins += (row['duration_minutes'] as num).toInt();
          }
        }
      }

      // 3. Tải danh sách luật điểm từ Admin để lấy Hệ số điểm
      final rulesRes = await Supabase.instance.client
          .from('gamification_rules')
          .select('rule_key, rule_name, points');

      // 4. Tính điểm ứng dụng và đếm số lượng hoạt động KNS
      final appResponse = await Supabase.instance.client
          .from('practical_applications')
          .select(
            'gamification_points, is_shared_group, coffee_talk_name, is_speaker, created_at, ai_score',
          )
          .eq('user_id', userId);

      int totalPts = 0, products = 0, shares = 0, coffee = 0, speakers = 0;
      int aiPts = 0,
          sharePts = 0,
          coffeePts = 0,
          speakerPts = 0; // Lưu điểm riêng từng mục

      // Lấy cấu hình điểm linh hoạt
      int knsMaxAi = 20;
      int tscMaxAi = 10;
      for (var r in rulesRes) {
        if (r['rule_key'] == 'kns_max_ai') knsMaxAi = r['points'];
        if (r['rule_key'] == 'tsc_max_ai') tscMaxAi = r['points'];
      }

      int shareConfigPts =
          (rulesRes as List).firstWhere(
            (r) => r['rule_key'] == 'share_group',
            orElse: () => {'points': 0},
          )['points'] ??
          5;
      int coffeeConfigPts =
          rulesRes.firstWhere(
            (r) => r['rule_key'] == 'coffee_talk',
            orElse: () => {'points': 0},
          )['points'] ??
          2;
      int speakerConfigPts =
          rulesRes.firstWhere(
            (r) => r['rule_key'] == 'speaker',
            orElse: () => {'points': 0},
          )['points'] ??
          50;

      for (var row in appResponse) {
        DateTime? createdAt = DateTime.tryParse(row['created_at'] ?? '');
        if (createdAt != null && sDate != null && eDate != null) {
          if (createdAt.isAfter(sDate.subtract(const Duration(days: 1))) &&
              createdAt.isBefore(eDate.add(const Duration(days: 1)))) {
            int rawGamificationPts =
                (row['gamification_points'] as num?)?.toInt() ?? 0;
            int rawAiPts = (row['ai_score'] as num?)?.toInt() ?? 0;

            // Nếu User 'all' đang xem đợt TSC, điểm cá nhân hiển thị trên topbar cũng scale tương ứng
            if (_isAllRole && activePeriod['target_role'] == 'tsc') {
              double scaled =
                  rawAiPts * (tscMaxAi / (knsMaxAi > 0 ? knsMaxAi : 1));
              totalPts += scaled.round();
              aiPts += scaled.round();
            } else {
              totalPts += rawGamificationPts;
              aiPts += rawAiPts;
            }

            products++;

            // Tiêu chí phụ: ẩn/không cộng nếu User 'all' đang xem đợt TSC
            bool skipExtra =
                (_isAllRole && activePeriod['target_role'] == 'tsc');

            if (row['is_shared_group'] == true && !skipExtra) {
              shares++;
              sharePts += shareConfigPts;
            }
            if (row['coffee_talk_name'] != null &&
                row['coffee_talk_name'].toString().trim().isNotEmpty &&
                !skipExtra) {
              coffee++;
              coffeePts += coffeeConfigPts;
            }
            if (row['is_speaker'] == true && !skipExtra) {
              speakers++;
              speakerPts += speakerConfigPts;
            }
          }
        }
      }

      // 5. Build danh sách thẻ KNS động kèm Điểm hiển thị
      List<Map<String, dynamic>> dynamicCards = [];
      for (var rule in rulesRes) {
        final key = rule['rule_key'] as String;
        final name = (rule['rule_name'] as String)
            .replaceAll('Điểm ', '')
            .replaceAll('dự ', '')
            .replaceAll('làm ', '');

        if (key == 'share_group') {
          dynamicCards.add({
            'name': name,
            'value': '$shares lần\n(+$sharePts đ)',
            'color': Colors.purple,
          });
        } else if (key == 'coffee_talk') {
          dynamicCards.add({
            'name': name,
            'value': '$coffee buổi\n(+$coffeePts đ)',
            'color': Colors.brown,
          });
        } else if (key == 'speaker') {
          dynamicCards.add({
            'name': name,
            'value': '$speakers lần\n(+$speakerPts đ)',
            'color': Colors.red,
          });
        }
      }

      if (mounted) {
        setState(() {
          _totalHours = totalMins;
          _totalPoints = totalPts;
          _totalProducts = products;
          _totalAiPts = aiPts;
          _knsDynamicCards = dynamicCards;
        });
      }

      // Gọi hàm tính toán thứ hạng sau khi đã xác định được sDate và eDate
      await _fetchUserRankings(sDate, eDate);
    } catch (e) {
      debugPrint('Lỗi tải số liệu cá nhân: $e');
    }
  }

  // Hàm tính toán thứ hạng cá nhân bằng Bảng Ảo (Tối ưu token & Sửa lỗi lọc Role)
  Future<void> _fetchUserRankings(DateTime? sDate, DateTime? eDate) async {
    try {
      final currentUserId = Supabase.instance.client.auth.currentUser?.id;
      if (currentUserId == null ||
          _division.isEmpty ||
          _division == 'Đang tải...') {
        return;
      }

      // Lấy cấu hình điểm max AI
      final rulesRes = await Supabase.instance.client
          .from('gamification_rules')
          .select('rule_key, points');
      int knsMaxAi = 20;
      int tscMaxAi = 10;
      for (var r in rulesRes) {
        if (r['rule_key'] == 'kns_max_ai') knsMaxAi = r['points'];
        if (r['rule_key'] == 'tsc_max_ai') tscMaxAi = r['points'];
      }

      // TẢI DỮ LIỆU TỪ BẢNG ẢO
      List<dynamic> events = [];
      int start = 0;
      while (true) {
        final res = await Supabase.instance.client
            .from('v_leaderboard_events')
            .select(
              'user_id, division, department_id, role, hours, points, ai_points, event_date',
            )
            .range(start, start + 999);
        events.addAll(res);
        if (res.length < 1000) break;
        start += 1000;
      }

      // Role của đợt đang xét dựa trên lựa chọn filter
      String targetRole = 'tsc';
      if (_selectedFilterPeriod != null &&
          _selectedFilterPeriod!.containsKey('target_role')) {
        targetRole = _selectedFilterPeriod!['target_role'] ?? 'tsc';
      } else if (_isKNS) {
        targetRole = 'kns';
      }

      Map<String, int> userHours = {};
      Map<String, int> userPoints = {};

      List<String> sysUserIds = [];
      List<String> divUserIds = [];
      List<String> deptUserIds = [];

      // Failsafe: Khởi tạo cho chính mình để xử lý điểm 0
      userHours[currentUserId] = 0;
      userPoints[currentUserId] = 0;

      // Khởi tạo List hệ thống dựa trên đợt đang xem
      if (targetRole == 'tsc' || _isAllRole) sysUserIds.add(currentUserId);
      divUserIds.add(currentUserId);
      if (_departmentId != null) deptUserIds.add(currentUserId);

      Set<String> processedUsers = {currentUserId};

      for (var ev in events) {
        String uid = ev['user_id']?.toString() ?? '';
        if (uid.isEmpty) continue;

        String userRole = ev['role']?.toString() ?? '';

        // CỐT LÕI: Lọc người cùng role hoặc role 'all'
        if (userRole != targetRole && userRole != 'all') continue;

        if (!processedUsers.contains(uid)) {
          processedUsers.add(uid);
          if (targetRole == 'tsc') {
            // Toàn hệ thống lấy mix tsc và all
            sysUserIds.add(uid);
          }
          if (ev['division'] == _division) divUserIds.add(uid);
          if (ev['department_id']?.toString() == _departmentId) {
            deptUserIds.add(uid);
          }
        }

        DateTime? recordDate = DateTime.tryParse(ev['event_date'] ?? '');
        int hrs = (ev['hours'] as num?)?.toInt() ?? 0;
        int pts = (ev['points'] as num?)?.toInt() ?? 0;
        int aiPts = (ev['ai_points'] as num?)?.toInt() ?? 0;

        // Xử lý chia tỷ lệ điểm nếu Đợt là TSC và user là Hybrid ('all')
        if (targetRole == 'tsc' && userRole == 'all') {
          double scaled = aiPts * (tscMaxAi / (knsMaxAi > 0 ? knsMaxAi : 1));
          pts = scaled.round();
        }

        if (recordDate != null && sDate != null && eDate != null) {
          if (recordDate.isAfter(sDate.subtract(const Duration(days: 1))) &&
              recordDate.isBefore(eDate.add(const Duration(days: 1)))) {
            userHours[uid] = (userHours[uid] ?? 0) + hrs;
            userPoints[uid] = (userPoints[uid] ?? 0) + pts;
          }
        }
      }

      // Hàm Helper để xếp hạng (LOẠI NGƯỜI 0 ĐIỂM)
      int getRank(
        List<String> groupIds,
        Map<String, int> dataMap,
        String myId,
      ) {
        if (groupIds.isEmpty) return 0;
        List<Map<String, dynamic>> list = groupIds
            .map((uid) => {'id': uid, 'score': dataMap[uid] ?? 0})
            .toList();
        list.sort((a, b) => (b['score'] as int).compareTo(a['score'] as int));

        // TRỌNG TÂM: Nếu mình có 0 điểm thì trả về 0 để UI hiện '--' thay vì hạng ảo
        if ((dataMap[myId] ?? 0) == 0) return 0;

        return list.indexWhere((e) => e['id'] == myId) + 1;
      }

      if (mounted) {
        setState(() {
          _rankHoursDept = getRank(deptUserIds, userHours, currentUserId);
          _rankHoursDiv = getRank(divUserIds, userHours, currentUserId);
          if (!_isKNS || _isAllRole) {
            _rankHoursSys = getRank(sysUserIds, userHours, currentUserId);
          }

          _rankPointsDept = getRank(deptUserIds, userPoints, currentUserId);
          _rankPointsDiv = getRank(divUserIds, userPoints, currentUserId);
          if (!_isKNS || _isAllRole) {
            _rankPointsSys = getRank(sysUserIds, userPoints, currentUserId);
          }
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải ranking cá nhân: $e');
    }
  }

  // Hàm lấy thông tin cán bộ từ Supabase
  Future<void> _fetchUserProfile() async {
    try {
      final userEmail = Supabase.instance.client.auth.currentUser?.email;
      if (userEmail == null) {
        if (mounted) {
          setState(() {
            _fullName = 'Chưa đăng nhập';
            _division = 'Vui lòng đăng nhập lại';
          });
        }
        return;
      }

      // Dùng maybeSingle() thay vì single() để không bị crash nếu DB chưa có dòng data của user này
      final data = await Supabase.instance.client
          .from('profiles')
          .select(
            'full_name, division, role, email, avatar_url, department_id, is_admin',
          )
          .ilike('email', userEmail.trim())
          .maybeSingle();

      String fetchedDept = '';
      if (data != null && data['department_id'] != null) {
        // Lấy thêm tên phòng từ bảng departments dựa vào ID
        final deptData = await Supabase.instance.client
            .from('departments')
            .select('department_name')
            .eq('id', data['department_id'])
            .maybeSingle();
        if (deptData != null) {
          fetchedDept = deptData['department_name'] ?? '';
        }
      }

      if (mounted) {
        setState(() {
          if (data != null) {
            _fullName = data['full_name'] ?? 'Chưa cập nhật tên';
            _division = data['division'] ?? 'Chưa cập nhật đơn vị';
            _department = fetchedDept;
            _departmentId = data['department_id']
                ?.toString(); // Ép kiểu sang chuỗi để tránh lỗi type int
            _isKNS = (data['role'] == 'kns');
            _isAllRole = (data['role'] == 'all');
            _avatarUrl = data['avatar_url'];

            // Phân quyền Admin: Đọc trực tiếp cờ is_admin từ Database
            _isAdmin = data['is_admin'] == true;
          } else {
            // Nếu không tìm thấy profile trên Supabase
            _fullName = 'Chưa có thông tin';
            _division = 'Vui lòng cập nhật profile';
          }
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải profile: $e');
      if (mounted) {
        setState(() {
          _fullName = 'Lỗi tải dữ liệu';
          _division = 'Kiểm tra kết nối Database';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.white, // Sửa nền AppBar thành màu trắng
        foregroundColor: const Color(
          0xFF0054A6,
        ), // Chữ và icon màu xanh VietinBank
        elevation: 2,
        shadowColor: Colors.black26,
        title: Image.asset(
          'assets/logo.png',
          height: 32, // Tăng nhẹ kích thước logo để cân đối
        ),
        actions: [
          PopupMenuButton<String>(
            offset: const Offset(0, 50),
            tooltip: 'Tài khoản',
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0),
              child: Row(
                children: [
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 150),
                        child: Text(
                          _fullName,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF0054A6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                      ConstrainedBox(
                        constraints: const BoxConstraints(
                          maxWidth: 220,
                        ), // Tăng độ rộng để chứa đủ cả Khối và Phòng
                        child: Text(
                          _department.isNotEmpty
                              ? '$_division - $_department'
                              : _division,
                          style: const TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  CircleAvatar(
                    radius: 18,
                    backgroundColor: Colors.blue.shade50,
                    backgroundImage: _avatarUrl != null
                        ? NetworkImage(_avatarUrl!)
                        : null,
                    child: _avatarUrl == null
                        ? const Icon(
                            Icons.person,
                            size: 22,
                            color: Color(0xFF0054A6),
                          )
                        : null,
                  ),
                ],
              ),
            ),
            onSelected: (value) {
              if (value == 'profile') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const ProfileScreen(),
                  ),
                ).then(
                  (_) => _fetchUserProfile(),
                ); // Tải lại Avatar/Tên nếu user vừa đổi
              } else if (value == 'settings') {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const AdminSetupScreen(),
                  ),
                ).then((_) {
                  _fetchLearningStats();
                });
              } else if (value == 'report_issue') {
                _showReportIssueDialog(); // Hiển thị Form báo cáo trực tiếp
              } else if (value == 'logout') {
                Supabase.instance.client.auth.signOut();
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              PopupMenuItem<String>(
                enabled: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _fullName,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _department.isNotEmpty
                          ? '$_division\n$_department'
                          : _division,
                      style: const TextStyle(color: Colors.grey, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem<String>(
                value: 'profile',
                child: Row(
                  children: [
                    Icon(
                      Icons.manage_accounts,
                      color: Colors.black54,
                      size: 20,
                    ),
                    SizedBox(width: 12),
                    Text(
                      'Cập nhật hồ sơ',
                      style: TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              if (_isAdmin)
                const PopupMenuItem<String>(
                  value: 'settings',
                  child: Row(
                    children: [
                      Icon(Icons.settings, color: Colors.black54, size: 20),
                      SizedBox(width: 12),
                      Text(
                        'Cài đặt',
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              const PopupMenuItem<String>(
                value: 'report_issue',
                child: Row(
                  children: [
                    Icon(Icons.bug_report, color: Colors.orange, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Báo lỗi / Góp ý',
                      style: TextStyle(
                        color: Colors.black87,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
              const PopupMenuItem<String>(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, color: Colors.red, size: 20),
                    SizedBox(width: 12),
                    Text(
                      'Đăng xuất',
                      style: TextStyle(
                        color: Colors.red,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 1. Module Kê khai nhanh giờ học
            QuickLogWidget(
              onSavedSuccess: () {
                _fetchLearningStats();
              },
            ),
            const SizedBox(height: 24),

            // 3. Module Thống kê tổng quan (Cá nhân) kèm Bộ lọc
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    'Tiến trình: $_activePeriodName',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF0054A6),
                    ),
                  ),
                ),
                if (_availablePeriods.isNotEmpty)
                  DropdownButton<String>(
                    value: _selectedFilterPeriod?['period_name'],
                    icon: const Icon(
                      Icons.filter_list,
                      size: 20,
                      color: Color(0xFF0054A6),
                    ),
                    underline: const SizedBox(),
                    style: const TextStyle(
                      color: Color(0xFF0054A6),
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                    alignment: Alignment.centerRight,
                    items: _availablePeriods.map((period) {
                      return DropdownMenuItem<String>(
                        value: period['period_name'],
                        child: Text(period['period_name']),
                      );
                    }).toList(),
                    onChanged: (val) {
                      setState(() {
                        _selectedFilterPeriod = _availablePeriods.firstWhere(
                          (p) => p['period_name'] == val,
                        );
                      });
                      // Khi chọn chặng khác, tải lại toàn bộ số liệu
                      _fetchLearningStats();
                    },
                  ),
              ],
            ),
            const SizedBox(height: 12),
            // UX/UI Mới: Phân cấp rõ ràng 2 tiêu chí chính
            Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) =>
                            const HistoryScreen(initialIndex: 0),
                      ),
                    ),
                    child: _buildStatCard(
                      'Tổng giờ học',
                      '$_totalHours phút',
                      Colors.green,
                      isHighlight: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _buildStatCard(
                    'Tổng điểm ứng dụng',
                    '$_totalPoints điểm',
                    Colors.blue,
                    isHighlight: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              'Chi tiết điểm ứng dụng',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            // Dải cuộn ngang cho các thẻ chi tiết phụ
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) =>
                              const HistoryScreen(initialIndex: 1),
                        ),
                      ),
                      child: _buildStatCard(
                        'SP Ứng dụng',
                        '$_totalProducts SP\n(+$_totalAiPts đ)',
                        Colors.red,
                        isHighlight: false,
                        isDetail: true,
                      ),
                    ),
                    if (_isKNS) ...[
                      ..._knsDynamicCards.map(
                        (card) => Padding(
                          padding: const EdgeInsets.only(left: 12.0),
                          child: _buildStatCard(
                            card['name'],
                            card['value'],
                            card['color'],
                            isHighlight: false,
                            isDetail: true,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            // UI Thể hiện Ranking (Thứ tự)
            _buildRankCard(
              '$_activePeriodName - Xếp hạng theo Số giờ học tập',
              _rankHoursDept,
              _rankHoursDiv,
              _rankHoursSys,
              Icons.timer,
              Colors.blue,
            ),
            _buildRankCard(
              '$_activePeriodName - Xếp hạng theo Điểm ứng dụng',
              _rankPointsDept,
              _rankPointsDiv,
              _rankPointsSys,
              Icons.emoji_events,
              Colors.red,
            ),

            const Center(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: 8.0),
                child: Text(
                  '* Chi tiết bảng xếp hạng vui lòng xem tại tab Báo cáo bên dưới',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontStyle: FontStyle.italic,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildStatCard(
    String title,
    String value,
    MaterialColor color, {
    bool isHighlight = false,
    bool isDetail = false,
  }) {
    // Thu nhỏ thẻ chi tiết xuống 130px trên Mobile để nhìn được nhiều hơn, giữ 150px trên Web
    // Các thẻ highlight (Hàng trên) không bị ép Width vì được quản lý bởi Expanded
    double? cardWidth;
    if (isDetail) {
      cardWidth = MediaQuery.of(context).size.width < 600 ? 130 : 150;
    }

    IconData cardIcon = Icons.local_fire_department;
    if (title.toLowerCase().contains('giờ')) {
      cardIcon = Icons.timer;
    }
    if (title.toLowerCase().contains('sp') ||
        title.toLowerCase().contains('ứng dụng')) {
      cardIcon = Icons.stars;
    }
    if (title.toLowerCase().contains('điểm')) {
      cardIcon = Icons.emoji_events;
    }
    if (title.toLowerCase().contains('share')) {
      cardIcon = Icons.share;
    }
    if (title.toLowerCase().contains('speaker')) {
      cardIcon = Icons.mic;
    }
    if (title.toLowerCase().contains('coffee')) {
      cardIcon = Icons.coffee;
    }

    return Container(
      width: cardWidth,
      padding: EdgeInsets.symmetric(
        horizontal: isHighlight ? 16 : 12,
        vertical: isHighlight ? 16 : 8,
      ),
      decoration: BoxDecoration(
        color: isHighlight ? null : Colors.white,
        gradient: isHighlight
            ? LinearGradient(
                colors: [color.shade400, color.shade700],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              )
            : null,
        borderRadius: BorderRadius.circular(isHighlight ? 16 : 12),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: isHighlight ? 0.3 : 0.05),
            blurRadius: isHighlight ? 8 : 4,
            offset: Offset(0, isHighlight ? 4 : 2),
          ),
        ],
        border: isHighlight
            ? null
            : Border.all(color: color.shade100, width: 1),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                cardIcon,
                color: isHighlight ? Colors.white : color,
                size: isHighlight ? 22 : 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: isHighlight ? 13 : 11,
                    color: isHighlight
                        ? Colors.white.withValues(alpha: 0.9)
                        : Colors.grey[700],
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          SizedBox(height: isHighlight ? 12 : 8),
          Text(
            value,
            style: TextStyle(
              fontSize: isHighlight ? 20 : 15,
              fontWeight: FontWeight.w900,
              color: isHighlight ? Colors.white : color.shade700,
            ),
          ),
        ],
      ),
    );
  }

  // Widget vẽ thẻ Xếp hạng
  Widget _buildRankCard(
    String title,
    int rankDept,
    int rankDiv,
    int rankSys,
    IconData icon,
    MaterialColor color,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.shade100, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.05),
            blurRadius: 5,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color.shade700, size: 22),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: color.shade800,
                  ),
                ),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12.0),
            child: Divider(height: 1, thickness: 1),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: _buildRankItem(
                  _department.isNotEmpty ? _department : 'Phòng',
                  rankDept,
                  color,
                ),
              ),
              Container(width: 1, height: 30, color: Colors.grey.shade300),
              Expanded(
                child: _buildRankItem(
                  _division.isNotEmpty ? _division : 'Khối',
                  rankDiv,
                  color,
                ),
              ),
              if (!_isKNS ||
                  (_isAllRole &&
                      _selectedFilterPeriod?['target_role'] == 'tsc')) ...[
                Container(width: 1, height: 30, color: Colors.grey.shade300),
                Expanded(
                  child: _buildRankItem('Toàn hệ thống', rankSys, color),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildRankItem(String label, int rank, MaterialColor color) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4.0),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: Colors.grey.shade600,
              height: 1.2,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          rank > 0 ? 'Hạng $rank' : '--',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w900,
            color: color.shade700,
          ),
        ),
      ],
    );
  }
}
