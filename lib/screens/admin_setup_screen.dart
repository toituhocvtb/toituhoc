import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AdminSetupScreen extends StatefulWidget {
  const AdminSetupScreen({super.key});

  @override
  State<AdminSetupScreen> createState() => _AdminSetupScreenState();
}

class _AdminSetupScreenState extends State<AdminSetupScreen> {
  List<dynamic> _periods = [];
  bool _isLoading = true;
  final Map<String, int> _points = {}; // Lưu điểm trực tiếp

  @override
  void initState() {
    super.initState();
    _fetchPeriods();
    _fetchPoints(); // Gọi thêm hàm tải điểm
  }

  // Tải cấu hình điểm từ Database để hiển thị ra 2 thẻ
  Future<void> _fetchPoints() async {
    try {
      final res = await Supabase.instance.client
          .from('gamification_rules')
          .select();
      if (mounted) {
        setState(() {
          for (var row in res) {
            _points[row['rule_key']] = row['points'] as int;
          }
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải cấu hình điểm: $e');
    }
  }

  Future<void> _fetchPeriods() async {
    setState(() => _isLoading = true);
    try {
      final response = await Supabase.instance.client
          .from('learning_periods')
          .select();

      final now = DateTime.now();

      // Khởi tạo thuật toán sắp xếp thông minh
      List<dynamic> sortedList = List.from(response);
      sortedList.sort((a, b) {
        final aActive = a['is_active'] == true;
        final bActive = b['is_active'] == true;

        // Cộng thêm 1 ngày vào end_date để cho phép nộp bài đến hết ngày cuối cùng 23:59
        DateTime aEnd;
        try {
          aEnd = DateTime.parse(a['end_date']).add(const Duration(days: 1));
        } catch (_) {
          aEnd = now;
        }
        DateTime bEnd;
        try {
          bEnd = DateTime.parse(b['end_date']).add(const Duration(days: 1));
        } catch (_) {
          bEnd = now;
        }

        final aExpired = now.isAfter(aEnd);
        final bExpired = now.isAfter(bEnd);

        // Cấp độ ưu tiên (Càng nhỏ càng đứng đầu danh sách)
        // 0: Đang Active NHƯNG đã hết hạn (Báo Đỏ - Nguy hiểm)
        // 1: Đang Active và trong hạn (Báo Xanh dương)
        // 2: Đã tắt (Không Active)
        int getPriority(bool active, bool expired) {
          if (active && expired) return 0;
          if (active && !expired) return 1;
          return 2;
        }

        int pA = getPriority(aActive, aExpired);
        int pB = getPriority(bActive, bExpired);

        if (pA != pB) return pA.compareTo(pB);

        // Nếu cùng nhóm ưu tiên, đợt nào tạo sau/thời gian mới nhất sẽ xếp lên trên
        DateTime aStart;
        try {
          aStart = DateTime.parse(a['start_date']);
        } catch (_) {
          aStart = now;
        }
        DateTime bStart;
        try {
          bStart = DateTime.parse(b['start_date']);
        } catch (_) {
          bStart = now;
        }

        return bStart.compareTo(aStart);
      });

      if (mounted) {
        setState(() {
          _periods = sortedList;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải danh sách Đợt: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _toggleActive(String id, bool currentValue, String role) async {
    try {
      // Tùy chọn: Nếu bật 1 đợt lên, tự động tắt các đợt khác cùng role
      if (!currentValue) {
        await Supabase.instance.client
            .from('learning_periods')
            .update({'is_active': false})
            .eq('target_role', role);
      }

      await Supabase.instance.client
          .from('learning_periods')
          .update({'is_active': !currentValue})
          .eq('id', id);

      _fetchPeriods();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Cập nhật trạng thái thành công!'),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _deletePeriod(String id) async {
    try {
      await Supabase.instance.client
          .from('learning_periods')
          .delete()
          .eq('id', id);
      _fetchPeriods();

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Đã xóa thành công!')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Lỗi xóa: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  void _showAddDialog() {
    String selectedRole = 'tsc';
    final nameController = TextEditingController();
    DateTime? startDate;
    DateTime? endDate;

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Thêm Chặng/Đợt mới'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: selectedRole,
                      decoration: const InputDecoration(
                        labelText: 'Áp dụng cho khối',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'tsc',
                          child: Text('Trụ sở chính (TSC)'),
                        ),
                        DropdownMenuItem(
                          value: 'kns',
                          child: Text('Khối Nhân sự (KNS)'),
                        ),
                      ],
                      onChanged: (val) =>
                          setStateDialog(() => selectedRole = val!),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Tên hiển thị (VD: Đợt 1)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        startDate == null
                            ? 'Chọn ngày bắt đầu'
                            : 'Bắt đầu: ${startDate!.day}/${startDate!.month}/${startDate!.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setStateDialog(() => startDate = picked);
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        endDate == null
                            ? 'Chọn ngày kết thúc'
                            : 'Kết thúc: ${endDate!.day}/${endDate!.month}/${endDate!.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: startDate ?? DateTime.now(),
                          firstDate: DateTime(2020),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setStateDialog(() => endDate = picked);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Hủy'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nameController.text.isEmpty ||
                        startDate == null ||
                        endDate == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Vui lòng điền đủ thông tin!'),
                        ),
                      );
                      return;
                    }

                    Navigator.pop(ctx); // Đóng popup

                    try {
                      await Supabase.instance.client
                          .from('learning_periods')
                          .insert({
                            'target_role': selectedRole,
                            'period_name': nameController.text.trim(),
                            'start_date': startDate!.toIso8601String().split(
                              'T',
                            )[0],
                            'end_date': endDate!.toIso8601String().split(
                              'T',
                            )[0],
                            'is_active': false,
                          });
                      _fetchPeriods();
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text('Lỗi thêm mới: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _checkAndShowEditDialog(Map<String, dynamic> item) async {
    // Hiện loading trong lúc truy vấn dữ liệu chặng
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const Center(child: CircularProgressIndicator()),
    );

    bool hasData = false;
    try {
      final startStr = item['start_date'];
      final endStr = item['end_date'];

      // Kiểm tra bảng giờ học
      final hours = await Supabase.instance.client
          .from('learning_hours')
          .select('id')
          .gte('created_at', startStr)
          .lte('created_at', '$endStr 23:59:59')
          .limit(1);

      if (hours.isNotEmpty) {
        hasData = true;
      } else {
        // Kiểm tra bảng ứng dụng
        final apps = await Supabase.instance.client
            .from('practical_applications')
            .select('id')
            .gte('created_at', startStr)
            .lte('created_at', '$endStr 23:59:59')
            .limit(1);
        if (apps.isNotEmpty) hasData = true;
      }
    } catch (e) {
      debugPrint('Lỗi check data: $e');
      hasData = true; // An toàn: Lỗi thì khóa lại luôn
    }

    if (!mounted) return;
    Navigator.pop(context); // Tắt loading

    _showEditPeriodDialog(item, hasData);
  }

  void _showEditPeriodDialog(Map<String, dynamic> item, bool hasData) {
    final nameController = TextEditingController(text: item['period_name']);
    DateTime? startDate;
    DateTime? endDate;

    try {
      startDate = DateTime.parse(item['start_date']);
      endDate = DateTime.parse(item['end_date']);
    } catch (_) {}

    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            return AlertDialog(
              title: const Text('Sửa Chặng/Đợt thi đua'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: nameController,
                      decoration: const InputDecoration(
                        labelText: 'Tên hiển thị (VD: Đợt 1)',
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        startDate == null
                            ? 'Chọn ngày bắt đầu'
                            : 'Bắt đầu: ${startDate!.day}/${startDate!.month}/${startDate!.year}',
                        style: TextStyle(
                          color: hasData ? Colors.grey : Colors.black87,
                        ),
                      ),
                      subtitle: hasData
                          ? const Text(
                              'Đã có dữ liệu phát sinh, không thể sửa ngày bắt đầu',
                              style: TextStyle(color: Colors.red, fontSize: 12),
                            )
                          : null,
                      trailing: Icon(
                        Icons.calendar_today,
                        color: hasData ? Colors.grey : Colors.black54,
                      ),
                      onTap: hasData
                          ? null // Vô hiệu hóa nút bấm nếu đã có dữ liệu
                          : () async {
                              final picked = await showDatePicker(
                                context: context,
                                initialDate: startDate ?? DateTime.now(),
                                firstDate: DateTime(2020),
                                lastDate: DateTime(2030),
                              );
                              if (picked != null) {
                                setStateDialog(() {
                                  startDate = picked;
                                  // Tự động kéo ngày kết thúc lùi lại nếu nhỏ hơn ngày bắt đầu mới chọn
                                  if (endDate != null &&
                                      endDate!.isBefore(startDate!)) {
                                    endDate = startDate;
                                  }
                                });
                              }
                            },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        endDate == null
                            ? 'Chọn ngày kết thúc'
                            : 'Kết thúc: ${endDate!.day}/${endDate!.month}/${endDate!.year}',
                      ),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: endDate ?? startDate ?? DateTime.now(),
                          firstDate:
                              startDate ??
                              DateTime(
                                2020,
                              ), // Chặn chọn ngày quá khứ so với ngày bắt đầu
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setStateDialog(() => endDate = picked);
                        }
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Hủy'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (nameController.text.isEmpty ||
                        startDate == null ||
                        endDate == null) {
                      ScaffoldMessenger.of(ctx).showSnackBar(
                        const SnackBar(
                          content: Text('Vui lòng điền đủ thông tin!'),
                        ),
                      );
                      return;
                    }

                    Navigator.pop(ctx);

                    try {
                      await Supabase.instance.client
                          .from('learning_periods')
                          .update({
                            'period_name': nameController.text.trim(),
                            'start_date': startDate!.toIso8601String().split(
                              'T',
                            )[0],
                            'end_date': endDate!.toIso8601String().split(
                              'T',
                            )[0],
                          })
                          .eq('id', item['id']);
                      _fetchPeriods();
                      if (mounted) {
                        ScaffoldMessenger.of(this.context).showSnackBar(
                          const SnackBar(
                            content: Text('Cập nhật thành công!'),
                            backgroundColor: Colors.green,
                          ),
                        );
                      }
                    } catch (e) {
                      if (!mounted) return;
                      ScaffoldMessenger.of(this.context).showSnackBar(
                        SnackBar(
                          content: Text('Lỗi cập nhật: $e'),
                          backgroundColor: Colors.red,
                        ),
                      );
                    }
                  },
                  child: const Text('Lưu'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Hiển thị dialog để sửa cấu hình điểm (Render Động 100%)
  Future<void> _showEditPointsDialog() async {
    // Tải cấu hình điểm hiện tại từ DB
    final res = await Supabase.instance.client
        .from('gamification_rules')
        .select()
        .order('rule_name');

    // Khởi tạo danh sách Controller linh hoạt theo số dòng có trong DB
    List<Map<String, dynamic>> dynamicRules = List<Map<String, dynamic>>.from(
      res,
    );
    List<TextEditingController> controllers = dynamicRules.map((row) {
      return TextEditingController(text: row['points'].toString());
    }).toList();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Cấu hình Gamification'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // Vòng lặp tự đẻ ra TextField tương ứng số luật trong DB
              children: List.generate(dynamicRules.length, (index) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12.0),
                  child: TextField(
                    controller: controllers[index],
                    decoration: InputDecoration(
                      labelText: dynamicRules[index]['rule_name'],
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                );
              }),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Hủy'),
            ),
            ElevatedButton(
              onPressed: () async {
                Navigator.pop(ctx);
                try {
                  // Đóng gói mảng Update linh hoạt
                  List<Map<String, dynamic>> updates = [];
                  for (int i = 0; i < dynamicRules.length; i++) {
                    updates.add({
                      'rule_key': dynamicRules[i]['rule_key'],
                      'rule_name': dynamicRules[i]['rule_name'],
                      'points': int.parse(controllers[i].text),
                    });
                  }

                  await Supabase.instance.client
                      .from('gamification_rules')
                      .upsert(updates);

                  await _fetchPoints(); // Làm mới thẻ điểm ngay lập tức sau khi lưu

                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Lưu cấu hình điểm thành công!'),
                      backgroundColor: Colors.green,
                    ),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Lỗi cập nhật: $e'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              },
              child: const Text('Lưu thay đổi'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cài đặt Chặng / Đợt thi đua'),
        backgroundColor: Colors.blueGrey,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tiêu đề 1
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Cấu hình điểm Gamification',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.blueGrey,
              ),
            ),
          ),
          // 2 Thẻ (Cards) hiển thị trực tiếp cấu hình điểm
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 12.0,
              vertical: 8.0,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Card(
                    elevation: 2,
                    color: Colors.purple.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.purple.shade200, width: 1),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Điểm KNS',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.purple,
                                  fontSize: 16,
                                ),
                              ),
                              Tooltip(
                                message: 'Chỉnh sửa điểm',
                                child: InkWell(
                                  onTap: _showEditPointsDialog,
                                  child: const Icon(
                                    Icons.edit_square,
                                    color: Colors.purple,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Divider(color: Colors.purple),
                          Text(
                            '• AI Tối đa: ${_points['kns_max_ai'] ?? '...'} đ',
                          ),
                          Text(
                            '• Chia sẻ Group: ${_points['share_group'] ?? '...'} đ',
                          ),
                          Text(
                            '• Coffee Talk: ${_points['coffee_talk'] ?? '...'} đ',
                          ),
                          Text('• Diễn giả: ${_points['speaker'] ?? '...'} đ'),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Card(
                    elevation: 2,
                    color: Colors.blue.shade50,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: Colors.blue.shade200, width: 1),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Điểm TSC',
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  color: Colors.blue,
                                  fontSize: 16,
                                ),
                              ),
                              Tooltip(
                                message: 'Chỉnh sửa điểm',
                                child: InkWell(
                                  onTap: _showEditPointsDialog,
                                  child: const Icon(
                                    Icons.edit_square,
                                    color: Colors.blue,
                                    size: 20,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const Divider(color: Colors.blue),
                          Text(
                            '• AI Tối đa: ${_points['tsc_max_ai'] ?? '...'} đ',
                          ),
                          const SizedBox(height: 4),
                          const Text(
                            '• Không áp dụng tiêu chí phụ',
                            style: TextStyle(
                              color: Colors.grey,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                          const SizedBox(height: 36),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Tiêu đề 2 và Nút Thêm mới
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Cài đặt các Chặng / Đợt thi đua',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Colors.blueGrey,
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: _showAddDialog,
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Thêm mới'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // Khu vực hiển thị danh sách
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _periods.isEmpty
                ? const Center(
                    child: Text('Chưa có cấu hình nào. Hãy thêm mới!'),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    itemCount: _periods.length,
                    itemBuilder: (context, index) {
                      final item = _periods[index];
                      final isTsc = item['target_role'] == 'tsc';
                      final isActive = item['is_active'] == true;

                      // Logic kiểm tra thẻ có bị Hết hạn hay không
                      DateTime endDate;
                      try {
                        endDate = DateTime.parse(
                          item['end_date'],
                        ).add(const Duration(days: 1));
                      } catch (_) {
                        endDate = DateTime.now();
                      }
                      final isExpired = DateTime.now().isAfter(endDate);

                      // Báo động đỏ: Đang bật (Active) nhưng Đã hết hạn (Expired)
                      final isAlert = isActive && isExpired;

                      return Card(
                        elevation: isAlert ? 4 : 1,
                        shape: isAlert
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: const BorderSide(
                                  color: Colors.red,
                                  width: 2,
                                ), // Viền đỏ dày
                              )
                            : null,
                        color: isAlert
                            ? Colors
                                  .red
                                  .shade50 // Nền đỏ nhạt
                            : (isActive ? Colors.blue.shade50 : Colors.white),
                        child: ListTile(
                          leading: CircleAvatar(
                            backgroundColor: isAlert
                                ? Colors.red
                                : (isTsc ? Colors.blue : Colors.purple),
                            child: Text(
                              isTsc ? 'TSC' : 'KNS',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          title: Text(
                            item['period_name'],
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isAlert
                                  ? Colors.red.shade900
                                  : (isActive
                                        ? Colors.blue.shade900
                                        : Colors.black87),
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Từ: ${item['start_date']} đến ${item['end_date']}',
                              ),
                              if (isAlert)
                                const Padding(
                                  padding: EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    '⚠️ Chặng đã hết hạn. Vui lòng tắt đi!',
                                    style: TextStyle(
                                      color: Colors.red,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: isActive,
                                onChanged: (val) => _toggleActive(
                                  item['id'],
                                  isActive,
                                  item['target_role'],
                                ),
                                activeThumbColor: isAlert
                                    ? Colors.red
                                    : Colors.green,
                                activeTrackColor: isAlert
                                    ? Colors.red.shade200
                                    : Colors.green.shade300,
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.edit,
                                  color: Colors.blue,
                                ),
                                tooltip: 'Sửa thời gian',
                                onPressed: () => _checkAndShowEditDialog(item),
                              ),
                              IconButton(
                                icon: const Icon(
                                  Icons.delete,
                                  color: Colors.red,
                                ),
                                tooltip: 'Xóa đợt',
                                onPressed: () {
                                  showDialog(
                                    context: context,
                                    builder: (ctx) => AlertDialog(
                                      title: const Text('Xác nhận xóa'),
                                      content: Text(
                                        'Bạn có chắc muốn xóa đợt "${item['period_name']}" không?',
                                      ),
                                      actions: [
                                        TextButton(
                                          onPressed: () => Navigator.pop(ctx),
                                          child: const Text('Hủy'),
                                        ),
                                        ElevatedButton(
                                          onPressed: () {
                                            Navigator.pop(ctx);
                                            _deletePeriod(item['id']);
                                          },
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: Colors.red,
                                          ),
                                          child: const Text(
                                            'Xóa',
                                            style: TextStyle(
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
