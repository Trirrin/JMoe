import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';

class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _service = JmService.instance;
  final _p1 = TextEditingController();
  final _p2 = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  bool _saving = false;

  @override
  void dispose() {
    _p1.dispose();
    _p2.dispose();
    super.dispose();
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final p1 = _p1.text;
    final p2 = _p2.text;
    if (p1.length < 6) {
      _snack(L.t('passwordTooShort'));
      return;
    }
    if (p1 != p2) {
      _snack(L.t('passwordMismatch'));
      return;
    }
    final uid = '${AppState.instance.member?['uid'] ?? ''}';
    if (uid.isEmpty) {
      _snack(L.t('notLoggedIn'));
      return;
    }
    setState(() => _saving = true);
    final r = await _service.saveProfile(
      uid,
      const {},
      newPassword: p1,
      newPasswordConfirm: p2,
    );
    if (!mounted) return;
    setState(() => _saving = false);
    if (r.ok) {
      _snack(L.t('profileSaved'));
      Navigator.of(context).pop();
    } else {
      _snack(r.message ?? L.t('operationFailed'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('changePassword')),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(L.t('save')),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          TextField(
            controller: _p1,
            obscureText: _obscure1,
            decoration: InputDecoration(
              labelText: L.t('newPassword'),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure1
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscure1 = !_obscure1),
              ),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _p2,
            obscureText: _obscure2,
            decoration: InputDecoration(
              labelText: L.t('confirmNewPassword'),
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: IconButton(
                icon: Icon(
                  _obscure2
                      ? Icons.visibility_off_outlined
                      : Icons.visibility_outlined,
                  size: 18,
                ),
                onPressed: () => setState(() => _obscure2 = !_obscure2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(
            L.t('profileSecurityTip'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
