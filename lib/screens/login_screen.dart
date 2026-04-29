import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _emailFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  bool _isLoading = false;
  bool _rememberMe = false;
  bool _obscureText = true; // Quản lý ẩn hiện mật khẩu
  bool _isSavedPassword =
      false; // Đánh dấu mật khẩu đang hiển thị là mật khẩu cũ đã lưu
  final LocalAuthentication auth = LocalAuthentication();

  Future<void> _authenticateWithBiometrics() async {
    try {
      final bool canAuthenticateWithBiometrics = await auth.canCheckBiometrics;
      final bool canAuthenticate =
          canAuthenticateWithBiometrics || await auth.isDeviceSupported();

      if (!canAuthenticate) return;

      final bool didAuthenticate = await auth.authenticate(
        localizedReason: 'Vui lòng xác thực để đăng nhập nhanh',
        options: const AuthenticationOptions(
          biometricOnly: true,
          stickyAuth: true,
        ),
      );

      if (didAuthenticate &&
          _emailController.text.isNotEmpty &&
          _passwordController.text.isNotEmpty) {
        _signIn();
      }
    } catch (e) {
      debugPrint('Lỗi xác thực sinh trắc học: $e');
    }
  }

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _rememberMe = prefs.getBool('remember_me') ?? false;
      if (_rememberMe) {
        _emailController.text = prefs.getString('saved_email') ?? '';
        String savedPass = prefs.getString('saved_password') ?? '';
        if (savedPass.isNotEmpty) {
          _passwordController.text = savedPass;
          _isSavedPassword = true; // Xác nhận đây là mật khẩu lưu từ trước
        }
      }
    });
  }

  Future<void> _signIn() async {
    setState(() {
      _isLoading = true;
    });

    try {
      String emailInput = _emailController.text.trim();
      final password = _passwordController.text.trim();

      // 1. Bẫy lỗi: Cảnh báo nếu người dùng gõ sai viettinbank (2 chữ t)
      if (emailInput.toLowerCase().contains('@viettinbank.vn')) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Bạn đang gõ sai địa chỉ email (@viettinbank.vn). Vui lòng nhập lại chính xác!',
            ),
            backgroundColor: Colors.red,
          ),
        );
        return; // Dừng đăng nhập, khối finally ở dưới sẽ tự động tắt vòng xoay loading
      }

      // 2. Tự động thêm đuôi tên miền nếu người dùng chỉ nhập User AD (không có dấu @)
      if (emailInput.isNotEmpty && !emailInput.contains('@')) {
        emailInput = '$emailInput@vietinbank.vn';
      }

      // Gọi API đăng nhập của Supabase với email đã được chuẩn hóa
      await Supabase.instance.client.auth.signInWithPassword(
        email: emailInput,
        password: password,
      );

      // Lưu hoặc xóa thông tin đăng nhập tùy theo trạng thái Checkbox
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('remember_me', _rememberMe);
      if (_rememberMe) {
        await prefs.setString('saved_email', _emailController.text.trim());
        await prefs.setString(
          'saved_password',
          password,
        ); // Lưu cả mật khẩu để tự điền lần sau
      } else {
        await prefs.remove('saved_email');
        await prefs.remove('saved_password');
      }

      // Nếu đăng nhập thành công, AuthGate ở main.dart sẽ tự động chuyển hướng
    } on AuthException catch (error) {
      if (!mounted) return; // Kiểm tra màn hình còn tồn tại không
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error.message), backgroundColor: Colors.red),
      );
    } catch (error) {
      if (!mounted) return; // Kiểm tra màn hình còn tồn tại không
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Đã xảy ra lỗi không xác định'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _emailFocusNode.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: LayoutBuilder(
        builder: (context, constraints) {
          final bool isWideScreen = constraints.maxWidth >= 1000;

          final double screenWidth = constraints.maxWidth;
          final double screenHeight = constraints.maxHeight;

          final double cardWidth = isWideScreen
              ? 470
              : (screenWidth > 560 ? 420 : screenWidth - 32);

          final double formRight = isWideScreen ? 70 : 16;
          final double formTop = isWideScreen ? screenHeight * 0.15 : 24;

          return Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fill(
                child: Transform.scale(
                  scale: isWideScreen
                      ? 1.45
                      : 1.1, // Tăng tỷ lệ scale để zoom to logo
                  alignment: Alignment
                      .bottomRight, // Neo góc dưới phải để đẩy logo lên trên và sang trái
                  child: Image.asset(
                    'assets/background.jpg',
                    fit: BoxFit.cover,
                    alignment: Alignment
                        .bottomRight, // Đảm bảo ảnh gốc bám sát lề phải và dưới, không bị hở
                  ),
                ),
              ),

              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.02)),
              ),

              SafeArea(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(
                    top: formTop,
                    right: formRight,
                    left: 16,
                    bottom: 24,
                  ),
                  child: Align(
                    alignment: isWideScreen
                        ? Alignment.topRight
                        : Alignment.center,
                    child: SizedBox(
                      width: cardWidth,
                      child: Card(
                        elevation: 12,
                        color: Colors.white.withValues(alpha: 0.93),
                        shadowColor: Colors.black.withValues(alpha: 0.28),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(40, 42, 40, 38),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'TÔI TỰ HỌC',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.w800,
                                  color: Color(0xFF003366),
                                  letterSpacing: 0.2,
                                ),
                              ),
                              const SizedBox(height: 18),
                              const Text(
                                'Đây là ứng dụng lưu trữ thông tin tự học được phát triển bởi Trường ĐT&PTNNL',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.35,
                                  color: Colors.black54,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              const SizedBox(height: 34),

                              TextField(
                                controller: _emailController,
                                focusNode: _emailFocusNode,
                                keyboardType: TextInputType.emailAddress,
                                textInputAction: TextInputAction.next,
                                onSubmitted: (_) {
                                  FocusScope.of(
                                    context,
                                  ).requestFocus(_passwordFocusNode);
                                },
                                decoration: const InputDecoration(
                                  labelText: 'User AD hoặc Email',
                                  prefixIcon: Icon(
                                    Icons.person,
                                    color: Colors.grey,
                                  ),
                                  border: OutlineInputBorder(),
                                  enabledBorder: OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: Color(0xFF9E9E9E),
                                      width: 1.2,
                                    ),
                                  ),
                                  focusedBorder: OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: Color(0xFF0054A6),
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 16),

                              TextField(
                                controller: _passwordController,
                                focusNode: _passwordFocusNode,
                                obscureText: _obscureText,
                                textInputAction: TextInputAction.done,
                                onSubmitted: (_) {
                                  if (!_isLoading) _signIn();
                                },
                                onTap: () {
                                  if (_isSavedPassword) {
                                    setState(() {
                                      _passwordController.clear();
                                      _isSavedPassword = false;
                                    });
                                  }
                                },
                                decoration: InputDecoration(
                                  labelText: 'Mật khẩu',
                                  prefixIcon: const Icon(
                                    Icons.lock,
                                    color: Colors.grey,
                                  ),
                                  suffixIcon: _isSavedPassword
                                      ? null
                                      : IconButton(
                                          icon: Icon(
                                            _obscureText
                                                ? Icons.visibility_off
                                                : Icons.visibility,
                                          ),
                                          onPressed: () {
                                            setState(() {
                                              _obscureText = !_obscureText;
                                            });
                                          },
                                        ),
                                  border: const OutlineInputBorder(),
                                  enabledBorder: const OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: Color(0xFF9E9E9E),
                                      width: 1.2,
                                    ),
                                  ),
                                  focusedBorder: const OutlineInputBorder(
                                    borderSide: BorderSide(
                                      color: Color(0xFF0054A6),
                                      width: 2,
                                    ),
                                  ),
                                ),
                              ),

                              const SizedBox(height: 10),

                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Row(
                                      children: [
                                        Checkbox(
                                          value: _rememberMe,
                                          activeColor: const Color(0xFF0054A6),
                                          onChanged: (value) {
                                            setState(() {
                                              _rememberMe = value ?? false;
                                            });
                                          },
                                        ),
                                        const Flexible(
                                          child: Text(
                                            'Ghi nhớ mật khẩu',
                                            style: TextStyle(
                                              fontSize: 14,
                                              color: Colors.black87,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  if (_isSavedPassword)
                                    IconButton(
                                      icon: const Icon(
                                        Icons.fingerprint,
                                        color: Color(0xFF0054A6),
                                        size: 32,
                                      ),
                                      onPressed: _authenticateWithBiometrics,
                                      tooltip: 'Đăng nhập nhanh',
                                    ),
                                ],
                              ),

                              const SizedBox(height: 18),

                              SizedBox(
                                height: 52,
                                child: ElevatedButton(
                                  onPressed: _isLoading ? null : _signIn,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFFED1C24),
                                    foregroundColor: Colors.white,
                                    elevation: 3,
                                    shadowColor: Colors.black26,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                  child: _isLoading
                                      ? const SizedBox(
                                          height: 20,
                                          width: 20,
                                          child: CircularProgressIndicator(
                                            color: Colors.white,
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text(
                                          'Đăng nhập',
                                          style: TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
