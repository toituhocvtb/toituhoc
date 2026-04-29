import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart'; // Thêm thư viện nhận diện nền tảng (Web/Windows/...)
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart'; // Gọi thêm thư viện chọn ảnh đa nền tảng

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoadingAvatar = false;
  bool _isSavingPassword = false;
  String? _avatarUrl;
  String _userEmail = '';

  @override
  void initState() {
    super.initState();
    _fetchCurrentProfile();
  }

  Future<void> _fetchCurrentProfile() async {
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        setState(() => _userEmail = user.email ?? '');

        final data = await Supabase.instance.client
            .from('profiles')
            .select('avatar_url')
            .ilike('email', user.email!.trim())
            .maybeSingle();
        if (data != null && mounted) {
          setState(() {
            _avatarUrl = data['avatar_url'];
          });
        }
      }
    } catch (e) {
      debugPrint('Lỗi tải profile: $e');
    }
  }

  Future<void> _uploadAvatar() async {
    final XFile? pickedImage = await ImagePicker().pickImage(
      source: ImageSource.gallery,
    );

    if (pickedImage != null && mounted) {
      Uint8List? imageBytes;

      // Kiểm tra nền tảng: Nếu là Web, Android, iOS thì bật màn hình Crop
      if (kIsWeb ||
          defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        CroppedFile? croppedFile = await ImageCropper().cropImage(
          sourcePath: pickedImage.path,
          uiSettings: [
            AndroidUiSettings(
              toolbarTitle: 'Căn chỉnh Avatar',
              toolbarColor: const Color(0xFF0054A6),
              toolbarWidgetColor: Colors.white,
              initAspectRatio: CropAspectRatioPreset.square,
              lockAspectRatio: true,
              cropStyle: CropStyle.circle,
              hideBottomControls: false,
            ),
            IOSUiSettings(
              title: 'Căn chỉnh Avatar',
              aspectRatioLockEnabled: true,
              resetAspectRatioEnabled: false,
            ),
            WebUiSettings(
              context: context,
              presentStyle: WebPresentStyle.dialog,
            ),
          ],
        );

        if (croppedFile != null) {
          imageBytes = await croppedFile.readAsBytes();
        } else {
          return; // Hủy nếu người dùng thoát màn hình cắt
        }
      } else {
        // Nếu chạy trên Windows Desktop (bỏ qua bước crop vì thư viện chưa hỗ trợ)
        imageBytes = await pickedImage.readAsBytes();
      }

      if (mounted) {
        setState(() => _isLoadingAvatar = true);
        try {
          final user = Supabase.instance.client.auth.currentUser!;
          final userEmail = user.email!;
          final fileName =
              '${user.id}_${DateTime.now().millisecondsSinceEpoch}.jpg';

          await Supabase.instance.client.storage
              .from('avatars')
              .uploadBinary(
                fileName,
                imageBytes,
                fileOptions: const FileOptions(contentType: 'image/jpeg'),
              );

          final publicUrl = Supabase.instance.client.storage
              .from('avatars')
              .getPublicUrl(fileName);

          final updatedProfile = await Supabase.instance.client
              .from('profiles')
              .update({'avatar_url': publicUrl})
              .ilike('email', userEmail.trim())
              .select('avatar_url')
              .maybeSingle();

          if (updatedProfile == null) {
            throw Exception(
              'Lưu ảnh lên Storage thành công nhưng không thể cập nhật Database. Vui lòng kiểm tra lại quyền RLS hoặc Email tồn tại.',
            );
          }

          setState(
            () => _avatarUrl =
                updatedProfile['avatar_url'] as String? ?? publicUrl,
          );

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Lưu Avatar thành công!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } catch (e) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Lỗi tải ảnh: $e\n(Kiểm tra lại Policy trên bucket "avatars")',
                ),
                backgroundColor: Colors.red,
              ),
            );
          }
        } finally {
          if (mounted) setState(() => _isLoadingAvatar = false);
        }
      }
    }
  }

  Future<void> _changePassword() async {
    final newPass = _newPasswordController.text;
    final confirmPass = _confirmPasswordController.text;

    if (newPass.isEmpty || confirmPass.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vui lòng nhập đủ thông tin!')),
      );
      return;
    }

    if (newPass.length < 6) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Mật khẩu mới phải có ít nhất 6 ký tự!')),
      );
      return;
    }

    if (newPass != confirmPass) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Mật khẩu xác nhận không khớp!'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSavingPassword = true);

    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: newPass),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Đổi mật khẩu thành công!'),
            backgroundColor: Colors.green,
          ),
        );
        _newPasswordController.clear();
        _confirmPasswordController.clear();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lỗi đổi mật khẩu: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSavingPassword = false);
    }
  }

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cập nhật hồ sơ'),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF0054A6),
        elevation: 1,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          children: [
            // Module 1: Avatar
            Center(
              child: Stack(
                alignment: Alignment.bottomRight,
                children: [
                  CircleAvatar(
                    radius: 50,
                    backgroundColor: Colors.blue.shade50,
                    backgroundImage: _avatarUrl != null
                        ? NetworkImage(_avatarUrl!)
                        : null,
                    child: _avatarUrl == null
                        ? const Icon(
                            Icons.person,
                            size: 60,
                            color: Color(0xFF0054A6),
                          )
                        : null,
                  ),
                  if (_isLoadingAvatar)
                    const Positioned.fill(child: CircularProgressIndicator())
                  else
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.blue[800],
                      child: IconButton(
                        icon: const Icon(
                          Icons.camera_alt,
                          size: 18,
                          color: Colors.white,
                        ),
                        onPressed: _uploadAvatar,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              _userEmail,
              style: const TextStyle(fontSize: 16, color: Colors.grey),
            ),
            const SizedBox(height: 32),

            // Module 2: Đổi mật khẩu
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                'Đổi mật khẩu',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _newPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Mật khẩu mới',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock_outline),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _confirmPasswordController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Xác nhận mật khẩu mới',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.lock),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _isSavingPassword ? null : _changePassword,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFED1C24),
                  foregroundColor: Colors.white,
                ),
                child: _isSavingPassword
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text(
                        'LƯU MẬT KHẨU',
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
    );
  }
}
