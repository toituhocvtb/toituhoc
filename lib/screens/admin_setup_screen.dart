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
  final Map<String, int> _configs = {}; // Lưu cấu hình số lượng ảnh
  final Map<String, String> _configNames = {}; // Lưu tên cấu hình

  @override
  void initState() {
    super.initState();
    _fetchPeriods();
    _fetchPoints(); // Gọi thêm hàm tải điểm
    _fetchConfigs(); // Gọi thêm hàm tải cấu hình ảnh
  }

  // Tải cấu hình số lượng ảnh từ Database
  Future<void> _fetchConfigs() async {
    try {
      final res = await Supabase.instance.client
          .from('system_configs')
          .select()
          .like(
            'config_key',
            'max_%',
          ) // Ẩn các config hệ thống (SMTP, AI), chỉ load cấu hình số lượng ảnh
          .order('config_name');
      if (mounted) {
        setState(() {
          _configs.clear(); // Xóa data cũ trước khi nạp mới
          _configNames.clear();
          for (var row in res) {
            final String key = row['config_key']?.toString() ?? '';
            if (key.isEmpty) continue; // Bỏ qua nếu key lỗi

            // Ép kiểu an toàn (Safe parsing) để tránh crash do dữ liệu null hoặc sai type
            _configs[key] =
                int.tryParse(row['config_value']?.toString() ?? '0') ?? 0;
            _configNames[key] = row['config_name']?.toString() ?? key;
          }
        });
      }
    } catch (e) {
      debugPrint('Lỗi tải cấu hình hệ thống: $e');
    }
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

        return bStart.compareTo(aStart); // Xếp chặng mới nhất lên trên
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
    DateTime? cutoffDate;

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
                          setStateDialog(() {
                            endDate = picked;
                            if (cutoffDate == null ||
                                cutoffDate!.isBefore(endDate!)) {
                              cutoffDate = endDate;
                            }
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        cutoffDate == null
                            ? 'Chọn ngày chặn kê khai (Cut-off)'
                            : 'Chặn nộp: ${cutoffDate!.day}/${cutoffDate!.month}/${cutoffDate!.year}',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      trailing: Icon(Icons.block, color: Colors.red.shade700),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: cutoffDate ?? endDate ?? DateTime.now(),
                          firstDate: endDate ?? DateTime.now(),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setStateDialog(() => cutoffDate = picked);
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
                            'claim_cutoff_date': (cutoffDate ?? endDate!)
                                .toIso8601String()
                                .split('T')[0],
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
    DateTime? cutoffDate;

    try {
      startDate = DateTime.parse(item['start_date']);
      endDate = DateTime.parse(item['end_date']);
      cutoffDate = item['claim_cutoff_date'] != null
          ? DateTime.parse(item['claim_cutoff_date'])
          : endDate;
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
                          setStateDialog(() {
                            endDate = picked;
                            if (cutoffDate == null ||
                                cutoffDate!.isBefore(endDate!)) {
                              cutoffDate = endDate;
                            }
                          });
                        }
                      },
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(
                        cutoffDate == null
                            ? 'Chọn ngày chặn kê khai (Cut-off)'
                            : 'Chặn nộp: ${cutoffDate!.day}/${cutoffDate!.month}/${cutoffDate!.year}',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      trailing: Icon(Icons.block, color: Colors.red.shade700),
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: cutoffDate ?? endDate ?? DateTime.now(),
                          firstDate: endDate ?? DateTime.now(),
                          lastDate: DateTime(2030),
                        );
                        if (picked != null) {
                          setStateDialog(() => cutoffDate = picked);
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
                            'claim_cutoff_date': (cutoffDate ?? endDate!)
                                .toIso8601String()
                                .split('T')[0],
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

  // Hiển thị dialog để sửa cấu hình số lượng ảnh (Render Động 100% từ DB)
  Future<void> _showEditConfigsDialog() async {
    // Tải trực tiếp từ DB để đảm bảo luôn có dữ liệu mới nhất (giống cấu hình điểm)
    final res = await Supabase.instance.client
        .from('system_configs')
        .select()
        .like(
          'config_key',
          'max_%',
        ) // Ẩn các config hệ thống (SMTP, AI), chỉ load cấu hình số lượng ảnh
        .order('config_name');

    List<Map<String, dynamic>> dynamicConfigs = List<Map<String, dynamic>>.from(
      res,
    );
    List<TextEditingController> controllers = dynamicConfigs.map((row) {
      return TextEditingController(text: (row['config_value'] ?? 0).toString());
    }).toList();

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Cấu hình Số lượng ảnh tối đa'),
          content: SingleChildScrollView(
            child: dynamicConfigs.isEmpty
                ? const Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'Không tìm thấy dữ liệu. Hãy kiểm tra:\n1. Có đang chạy nhầm bản build cũ lỗi (chưa chạy flutter clean)?\n2. Bảng system_configs trên Supabase có bị khóa RLS không?',
                      style: TextStyle(color: Colors.red, height: 1.5),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(dynamicConfigs.length, (index) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 12.0),
                        child: TextField(
                          controller: controllers[index],
                          decoration: InputDecoration(
                            labelText:
                                dynamicConfigs[index]['config_name'] ??
                                dynamicConfigs[index]['config_key'],
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
            if (dynamicConfigs.isNotEmpty)
              ElevatedButton(
                onPressed: () async {
                  Navigator.pop(ctx);
                  try {
                    List<Map<String, dynamic>> updates = [];
                    for (int i = 0; i < dynamicConfigs.length; i++) {
                      updates.add({
                        'config_key': dynamicConfigs[i]['config_key'],
                        'config_name': dynamicConfigs[i]['config_name'],
                        'config_value': int.tryParse(controllers[i].text) ?? 1,
                      });
                    }

                    await Supabase.instance.client
                        .from('system_configs')
                        .upsert(updates);

                    await _fetchConfigs(); // Làm mới thẻ cấu hình ở màn hình ngoài

                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Lưu cấu hình ảnh thành công!'),
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
      // Bọc SingleChildScrollView để toàn bộ màn hình có thể cuộn lên
      body: SingleChildScrollView(
        child: Column(
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
                        side: BorderSide(
                          color: Colors.purple.shade200,
                          width: 1,
                        ),
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
                            Text(
                              '• Diễn giả: ${_points['speaker'] ?? '...'} đ',
                            ),
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

            // Thẻ (Card) hiển thị trực tiếp cấu hình Số lượng ảnh
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                'Cấu hình Giới hạn ảnh minh chứng',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.blueGrey,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 12.0,
                vertical: 8.0,
              ),
              child: Card(
                elevation: 2,
                color: Colors.orange.shade50,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.orange.shade200, width: 1),
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
                            'Số lượng ảnh tối đa cho phép',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: Colors.deepOrange,
                              fontSize: 16,
                            ),
                          ),
                          Tooltip(
                            message: 'Chỉnh sửa giới hạn ảnh',
                            child: InkWell(
                              onTap: _showEditConfigsDialog,
                              child: const Icon(
                                Icons.edit_square,
                                color: Colors.deepOrange,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const Divider(color: Colors.orange),
                      ..._configs.keys.map(
                        (key) => Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3.0),
                          child: Text(
                            '• ${_configNames[key] ?? key}: ${_configs[key] ?? '...'} ảnh',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Tiêu đề 2 và Nút Thêm mới
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'Cài đặt chặng thi đua',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.blueGrey,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
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
            _isLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: CircularProgressIndicator(),
                    ),
                  )
                : _periods.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('Chưa có cấu hình nào. Hãy thêm mới!'),
                    ),
                  )
                : ListView.builder(
                    shrinkWrap:
                        true, // Ép ListView nằm gọn trong SingleChildScrollView
                    physics:
                        const NeverScrollableScrollPhysics(), // Tắt cuộn của ListView
                    padding: const EdgeInsets.symmetric(horizontal: 12.0),
                    itemCount: _periods.length,
                    itemBuilder: (context, index) {
                      final item = _periods[index];
                      final isTsc = item['target_role'] == 'tsc';

                      // Xác định Active động dựa vào start_date và end_date
                      DateTime sDate = DateTime.now();
                      DateTime eDate = DateTime.now();
                      DateTime cutoffDate = DateTime.now();
                      String startFmt = item['start_date'];
                      String endFmt = item['end_date'];
                      String cutoffFmt = '';
                      try {
                        sDate = DateTime.parse(item['start_date']);
                        eDate = DateTime.parse(item['end_date']);
                        cutoffDate = item['claim_cutoff_date'] != null
                            ? DateTime.parse(item['claim_cutoff_date'])
                            : eDate;

                        startFmt =
                            '${sDate.day.toString().padLeft(2, '0')}/${sDate.month.toString().padLeft(2, '0')}/${sDate.year.toString().substring(2)}';
                        endFmt =
                            '${eDate.day.toString().padLeft(2, '0')}/${eDate.month.toString().padLeft(2, '0')}/${eDate.year.toString().substring(2)}';
                        cutoffFmt =
                            '${cutoffDate.day.toString().padLeft(2, '0')}/${cutoffDate.month.toString().padLeft(2, '0')}/${cutoffDate.year.toString().substring(2)}';
                      } catch (_) {}

                      final now = DateTime.now();
                      final isActive =
                          now.isAfter(
                            sDate.subtract(const Duration(days: 1)),
                          ) &&
                          now.isBefore(eDate.add(const Duration(days: 1)));
                      final isExpired = now.isAfter(
                        cutoffDate.add(const Duration(days: 1)),
                      );

                      return Card(
                        elevation: isActive ? 4 : 1,
                        shape: isActive
                            ? RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                                side: BorderSide(
                                  color: Colors.blue.shade400,
                                  width: 2,
                                ), // Viền xanh cho chặng đang diễn ra
                              )
                            : null,
                        color: isActive
                            ? Colors
                                  .blue
                                  .shade50 // Nền xanh nhạt
                            : (isExpired ? Colors.grey.shade100 : Colors.white),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12.0,
                            vertical: 4.0,
                          ),
                          leading: CircleAvatar(
                            backgroundColor: isTsc
                                ? Colors.blue
                                : Colors.purple,
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
                            item['period_name'], // Hiện chặng mấy ở dòng trên cùng
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                              color: isActive
                                  ? Colors.blue.shade900
                                  : Colors.black87,
                            ),
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const SizedBox(height: 4),
                              Text('Từ: $startFmt - Đến: $endFmt'),
                              Text(
                                'Chặn nộp: $cutoffFmt',
                                style: TextStyle(
                                  color: Colors.red.shade700,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              if (isActive)
                                const Padding(
                                  padding: EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    '🔥 Đang diễn ra',
                                    style: TextStyle(
                                      color: Colors.blue,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                )
                              else if (isExpired)
                                const Padding(
                                  padding: EdgeInsets.only(top: 4.0),
                                  child: Text(
                                    '🔒 Đã chốt sổ',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          trailing: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(
                                          Icons.edit,
                                          color: Colors.blue,
                                          size: 20,
                                        ),
                                        tooltip: 'Sửa thời gian',
                                        onPressed: () =>
                                            _checkAndShowEditDialog(item),
                                      ),
                                    ),
                                    SizedBox(
                                      width: 32,
                                      height: 32,
                                      child: IconButton(
                                        padding: EdgeInsets.zero,
                                        icon: const Icon(
                                          Icons.delete,
                                          color: Colors.red,
                                          size: 20,
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
                                                  onPressed: () =>
                                                      Navigator.pop(ctx),
                                                  child: const Text('Hủy'),
                                                ),
                                                ElevatedButton(
                                                  onPressed: () {
                                                    Navigator.pop(ctx);
                                                    _deletePeriod(item['id']);
                                                  },
                                                  style:
                                                      ElevatedButton.styleFrom(
                                                        backgroundColor:
                                                            Colors.red,
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
                                    ),
                                  ],
                                ),
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
