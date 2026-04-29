import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart'; // Import thư viện Đa ngôn ngữ
import 'package:supabase_flutter/supabase_flutter.dart'; // Import thư viện Supabase

// Import 3 file màn hình vừa tạo
import 'screens/home_screen.dart';
import 'screens/application_screen.dart';
import 'screens/report_screen.dart';
import 'screens/login_screen.dart';

Future<void> main() async {
  // Đảm bảo Flutter framework đã sẵn sàng trước khi gọi code bất đồng bộ (async)
  WidgetsFlutterBinding.ensureInitialized();

  // Khởi tạo kết nối Supabase
  await Supabase.initialize(
    url: 'https://zfuvifbdcbnwxdaacpty.supabase.co',
    anonKey:
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpmdXZpZmJkY2Jud3hkYWFjcHR5Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzcwMzU5MjIsImV4cCI6MjA5MjYxMTkyMn0.jki9y5H8zXSN2_HY1UE6IhKPEpScuzEWJTfjw8_JhNI',
  );

  runApp(const ToiTuHocApp());
}

class ToiTuHocApp extends StatelessWidget {
  const ToiTuHocApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Tôi Tự Học',
      debugShowCheckedModeBanner: false,
      // Bắt đầu cấu hình ngôn ngữ
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('vi', 'VN'), // Hỗ trợ tiếng Việt
        Locale('en', 'US'), // Tiếng Anh (dự phòng)
      ],
      locale: const Locale('vi', 'VN'), // Ép mặc định app là Tiếng Việt
      // Kết thúc cấu hình ngôn ngữ
      theme: ThemeData(
        primarySwatch: Colors.blue,
        scaffoldBackgroundColor: Colors.grey[100],
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          elevation: 0,
        ),
      ),
      home: const AuthGate(),
    );
  }
}

// ==========================================
// NGƯỜI GÁC CỔNG ĐIỀU HƯỚNG TRẠNG THÁI (AUTH GATE)
// ==========================================
class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    // StreamBuilder lắng nghe trạng thái đăng nhập liên tục
    return StreamBuilder<AuthState>(
      stream: Supabase.instance.client.auth.onAuthStateChange,
      builder: (context, snapshot) {
        // Kiểm tra nếu chưa load xong
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }

        // Lấy session hiện tại
        final session = snapshot.data?.session;

        // Nếu có session (đã đăng nhập) -> Vào App
        if (session != null) {
          return const MainNavigator();
        }

        // Nếu không có session -> Bắt đăng nhập
        return const LoginScreen();
      },
    );
  }
}

class MainNavigator extends StatefulWidget {
  const MainNavigator({super.key});

  @override
  State<MainNavigator> createState() => _MainNavigatorState();
}

class _MainNavigatorState extends State<MainNavigator> {
  int _selectedIndex = 0;

  // Sử dụng danh sách màn hình từ thư mục screens
  final List<Widget> _screens = [
    const HomeScreen(),
    const ApplicationScreen(),
    const ReportScreen(),
  ];

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_selectedIndex],
      bottomNavigationBar: BottomNavigationBar(
        items: const <BottomNavigationBarItem>[
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Trang chủ'),
          BottomNavigationBarItem(
            icon: Icon(Icons.assignment_turned_in),
            label: 'Ứng dụng',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.bar_chart),
            label: 'Báo cáo',
          ),
        ],
        currentIndex: _selectedIndex,
        selectedItemColor: Colors.blue[800],
        onTap: _onItemTapped,
      ),
    );
  }
}
