import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';

/// 账号资料编辑页。
///
/// 只开放低风险字段：昵称 / 姓名 / 性别 / 生日 / 城市 / 国家 /
/// 职业 / 公司 / 学校 / 网站 / 简介。
/// **刻意不支持修改密码与邮箱**——凭据变更应在官方站点完成。
class ProfileEditPage extends StatefulWidget {
  const ProfileEditPage({super.key});

  @override
  State<ProfileEditPage> createState() => _ProfileEditPageState();
}

class _ProfileEditPageState extends State<ProfileEditPage> {
  final _service = JmService.instance;
  final _form = <String, TextEditingController>{};

  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _gender;
  String _uid = '';

  /// 修改密码（留空表示不改）
  final _newPass = TextEditingController();
  final _newPass2 = TextEditingController();
  bool _obscure1 = true;
  bool _obscure2 = true;
  String? _email;

  /// 可编辑的文本字段：(key, 多行?)
  static const _fields = <({String key, bool multiline})>[
    (key: 'nickName', multiline: false),
    (key: 'firstName', multiline: false),
    (key: 'lastName', multiline: false),
    (key: 'birthday', multiline: false),
    (key: 'city', multiline: false),
    (key: 'country', multiline: false),
    (key: 'occupation', multiline: false),
    (key: 'company', multiline: false),
    (key: 'school', multiline: false),
    (key: 'website', multiline: false),
    (key: 'aboutMe', multiline: true),
  ];

  @override
  void initState() {
    super.initState();
    for (final f in _fields) {
      _form[f.key] = TextEditingController();
    }
    _load();
  }

  @override
  void dispose() {
    for (final c in _form.values) {
      c.dispose();
    }
    _newPass.dispose();
    _newPass2.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final uid = '${AppState.instance.member?['uid'] ?? ''}';
    _uid = uid;
    if (uid.isEmpty) {
      setState(() {
        _loading = false;
        _error = L.t('notLoggedIn');
      });
      return;
    }
    final d = await _service.fetchProfile(uid);
    if (!mounted) return;
    if (d == null) {
      setState(() {
        _loading = false;
        _error = L.t('loadFailed');
      });
      return;
    }
    setState(() {
      for (final f in _fields) {
        final v = '${d[f.key] ?? ''}';
        _form[f.key]!.text = (v == 'null') ? '' : v;
      }
      _gender = d['gender'] == null ? null : '${d['gender']}';
      _email = AppState.instance.member?['email']?.toString();
      _loading = false;
    });
  }

  void _snack(String s) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final fields = <String, dynamic>{};
    _form.forEach((k, c) {
      if (c.text.trim().isNotEmpty) fields[k] = c.text.trim();
    });
    if (_gender != null) fields['gender'] = _gender;

    // 校验两次密码一致
    final p1 = _newPass.text;
    final p2 = _newPass2.text;
    if (p1.isNotEmpty || p2.isNotEmpty) {
      if (p1.length < 6) {
        setState(() => _saving = false);
        _snack(L.t('passwordTooShort'));
        return;
      }
      if (p1 != p2) {
        setState(() => _saving = false);
        _snack(L.t('passwordMismatch'));
        return;
      }
    }

    final r = await _service.saveProfile(
      _uid,
      fields,
      newPassword: p1.isEmpty ? null : p1,
      newPasswordConfirm: p2.isEmpty ? null : p2,
    );
    if (!mounted) return;
    setState(() => _saving = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          r.ok
              ? L.t('profileSaved')
              : (r.message ?? L.t('operationFailed')),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
    if (r.ok) {
      // 昵称变了要同步到本地会话
      final nick = fields['nickName'];
      if (nick is String && nick.isNotEmpty) {
        final m = Map<String, dynamic>.from(AppState.instance.member ?? {});
        m['nickname'] = nick;
        await AppState.instance.saveSession(AppState.instance.jwt, m);
      }
      if (mounted) Navigator.of(context).pop(true);
    }
  }

  String _label(String key) {
    switch (key) {
      case 'nickName':
        return L.t('pNickName');
      case 'firstName':
        return L.t('pFirstName');
      case 'lastName':
        return L.t('pLastName');
      case 'birthday':
        return L.t('pBirthday');
      case 'city':
        return L.t('pCity');
      case 'country':
        return L.t('pCountry');
      case 'occupation':
        return L.t('pOccupation');
      case 'company':
        return L.t('pCompany');
      case 'school':
        return L.t('pSchool');
      case 'website':
        return L.t('pWebsite');
      case 'aboutMe':
        return L.t('pAboutMe');
      default:
        return key;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(L.t('editProfile')),
        actions: [
          TextButton(
            onPressed: _saving || _loading ? null : _save,
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
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        onPressed: _load,
                        child: Text(L.t('retry')),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
                  children: [
                    // 性别（三选一）
                    Text(
                      L.t('pGender'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final g in ['Male', 'Female', 'Other'])
                          ChoiceChip(
                            label: Text(
                              g == 'Male'
                                  ? L.t('genderMale')
                                  : (g == 'Female'
                                      ? L.t('genderFemale')
                                      : L.t('genderOther')),
                              style: const TextStyle(fontSize: 12),
                            ),
                            selected: _gender == g,
                            onSelected: (_) => setState(() => _gender = g),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    // 文本字段
                    for (final f in _fields) ...[
                      TextField(
                        controller: _form[f.key],
                        maxLines: f.multiline ? 4 : 1,
                        decoration: InputDecoration(
                          labelText: _label(f.key),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    const SizedBox(height: 18),
                    Text(
                      L.t('changePassword'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _newPass,
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
                          onPressed: () =>
                              setState(() => _obscure1 = !_obscure1),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _newPass2,
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
                          onPressed: () =>
                              setState(() => _obscure2 = !_obscure2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      L.t('emailAddress'),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.mail_outline,
                              size: 18,
                              color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              _email ?? L.t('notSet'),
                              style: const TextStyle(fontSize: 13),
                            ),
                          ),
                          Icon(Icons.lock_outline,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant),
                        ],
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      L.t('profileSecurityTip'),
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.6,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
    );
  }
}
