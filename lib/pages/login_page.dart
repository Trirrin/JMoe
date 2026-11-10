import 'dart:async';
import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/jm_protocol.dart';
import '../core/jm_service.dart';
import '../core/sync_service.dart';
import '../core/l10n.dart';
import '../widgets/app_logo.dart';

/// 登录 / 注册 / 找回密码。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key, this.startWithRegister = false});
  final bool startWithRegister;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _pass2 = TextEditingController();
  final _email = TextEditingController();
  final _code = TextEditingController();

  late bool _register = widget.startWithRegister;
  bool _busy = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _user.dispose();
    _pass.dispose();
    _pass2.dispose();
    _email.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
      _info = null;
    });
    try {
      final service = JmService.instance;
      if (_register) {
        final r = await service.register(
          username: _user.text.trim(),
          password: _pass.text,
          passwordConfirm: _pass2.text,
          email: _email.text.trim(),
        );
        if (!mounted) return;
        if (r['code'] == 200) {
          setState(() => _info = L.t('registerOk'));
        } else {
          setState(() => _error = r['errorMsg']?.toString() ?? L.t('registerFail'));
        }
      } else {
        final r = await service.login(_user.text.trim(), _pass.text);
        if (!mounted) return;
        // 关键：登录失败时服务端返回 HTTP 401 + code=401 + errorMsg，
        // 必须严格校验成功态，否则失败也会被当成登录成功而直接退出页面。
        final code = int.tryParse('${r['code']}') ?? -1;
        final data = r['data'];
        final hasSession = data is Map &&
            data.isNotEmpty &&
            (data['token'] != null ||
                data['jwt'] != null ||
                data['access_token'] != null ||
                data['s'] != null ||
                data['uid'] != null ||
                data['username'] != null);

        if (code == 200 && data is Map && data.isNotEmpty) {
          final map = Map<String, dynamic>.from(data);
          // 服务端字段名为 jwttoken（长串 JWT）；s 是 26 位 session id，
          // 仅作为 Cookie AVS 使用，不可当作 Bearer token。
          final token = '${map['jwttoken'] ?? map['jwt'] ?? map['token'] ?? map['access_token'] ?? ''}';
          final info = map['member'] is Map
              ? Map<String, dynamic>.from(map['member'] as Map)
              : map;
          // 用户名兜底：接口可能只回 uid，用输入的用户名补上
          info['username'] ??= _user.text.trim();
          JmApi.instance.jwtToken = token;
          JmApi.instance.cookieValue = '${map['s'] ?? info['s'] ?? ''}';
          await AppState.instance.saveSession(token.isEmpty ? null : token, info);
          unawaited(SyncService.instance.syncFavorites());
          if (!mounted) return;
          Navigator.of(context).pop(true);
        } else if (code == 200 && !hasSession) {
          setState(() => _error = L.t('loginFailed'));
        } else {
          final msg = r['errorMsg']?.toString();
          setState(() {
            _error = (msg != null && msg.isNotEmpty)
                ? msg
                : '${L.t('loginFailed')} (code=$code)';
          });
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(_register ? L.t('register') : L.t('login'))),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 12),
          // 显示**应用图标**（与桌面图标同源），不是通用书籍图标
          const Center(child: AppLogo(size: 64)),
          const SizedBox(height: 16),
          Text(
            _register ? L.t('createAccount') : L.t('loginAccount'),
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 24),
          TextField(
            controller: _user,
            decoration:  InputDecoration(
              labelText: L.t('username'),
              prefixIcon: Icon(Icons.person_outline, size: 20),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration:  InputDecoration(
              labelText: L.t('password'),
              prefixIcon: Icon(Icons.lock_outline, size: 20),
            ),
          ),
          if (_register) ...[
            const SizedBox(height: 12),
            TextField(
              controller: _pass2,
              obscureText: true,
              decoration:  InputDecoration(
                labelText: L.t('confirmPassword'),
                prefixIcon: Icon(Icons.lock_reset, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              decoration:  InputDecoration(
                labelText: L.t('email'),
                prefixIcon: Icon(Icons.mail_outline, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    decoration:  InputDecoration(
                      labelText: L.t('emailCode'),
                      prefixIcon: Icon(Icons.verified_outlined, size: 20),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          final r = await JmService.instance.confirmRegister(
                            _user.text.trim(),
                            _code.text.trim(),
                          );
                          if (!mounted) return;
                          setState(() {
                            _info = r['code'] == 200
                                ? L.t('loginVerifyOk')
                                : '${r['errorMsg'] ?? L.t('loginVerifyFail')}';
                          });
                        },
                  child: Text(L.t('verify')),
                ),
              ],
            ),
          ],
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 12),
              ),
            ),
          if (_info != null)
            Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Text(
                _info!,
                style: TextStyle(color: theme.colorScheme.primary, fontSize: 12),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _busy ? null : _submit,
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(_register ? L.t('register') : L.t('login')),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => setState(() {
              _register = !_register;
              _error = null;
              _info = null;
            }),
            child: Text(_register ? L.t('haveAccount') : L.t('noAccount')),
          ),
        ],
      ),
    );
  }
}
