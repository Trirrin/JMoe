import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/jm_service.dart';
import '../core/l10n.dart';

/// 性别选择块：自带底色的胶囊。
///
/// 主题里 `chipTheme.side = BorderSide.none`，未选中的 ChoiceChip 在
/// 浅色背景上几乎不可见（用户反馈「性别选项控件没有背景」）。
/// 这里自绘一个始终有底色的块，选中时换成主色。
class _GenderChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _GenderChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary : scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected ? scheme.onPrimary : scheme.onSurfaceVariant,
            ),
          ),
        ),
      ),
    );
  }
}
/// 账号资料编辑页。
///
/// 只开放低风险字段：昵称 / 姓名 / 性别 / 生日 / 城市 / 国家 /
/// 职业 / 公司 / 学校 / 网站 / 简介。
/// **刻意不支持修改邮箱**——凭据变更应在官方站点完成。
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

  /// 修改密码已移到独立页面（change_password_page.dart），
  /// 本页不再持有密码字段。
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
    // `useredit/{uid}` 在部分账号上会返回**全空字段**（实测 nickName/
    // firstName 等全是 ""，但登录响应里 member 明明有值）。
    // 这时用本地会话的 member 兜底，否则用户看到「编辑资料一片空白」，
    // 会以为资料丢了。
    final member = AppState.instance.member ?? const <String, dynamic>{};
    Map<String, dynamic> merged;
    if (d == null) {
      merged = Map<String, dynamic>.from(member);
    } else {
      merged = Map<String, dynamic>.from(d);
      for (final f in _fields) {
        final v = '${merged[f.key] ?? ''}'.trim();
        if (v.isEmpty || v == 'null') {
          final local = '${member[f.key] ?? ''}'.trim();
          if (local.isNotEmpty && local != 'null') merged[f.key] = local;
        }
      }
      // gender 同理
      final g = '${merged['gender'] ?? ''}'.trim();
      if (g.isEmpty || g == 'null') {
        final lg = '${member['gender'] ?? ''}'.trim();
        if (lg.isNotEmpty && lg != 'null') merged['gender'] = lg;
      }
    }
    setState(() {
      for (final f in _fields) {
        final v = '${merged[f.key] ?? ''}';
        _form[f.key]!.text = (v == 'null' || v == '0000-00-00') ? '' : v;
      }
      _gender = merged['gender'] == null ? null : '${merged['gender']}';
      if (_gender != null && _gender!.isEmpty) _gender = null;
      _email = AppState.instance.member?['email']?.toString();
      _loading = false;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final fields = <String, dynamic>{};
    _form.forEach((k, c) {
      if (c.text.trim().isNotEmpty) fields[k] = c.text.trim();
    });
    if (_gender != null) fields['gender'] = _gender;

    // 密码不在这里改（已拆到独立的「修改密码」页）
    final r = await _service.saveProfile(_uid, fields);
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
                          _GenderChip(
                            label: g == 'Male'
                                ? L.t('genderMale')
                                : (g == 'Female'
                                    ? L.t('genderFemale')
                                    : L.t('genderOther')),
                            selected: _gender == g,
                            onTap: () => setState(() => _gender = g),
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
                    // 修改密码已拆成独立页面（与「编辑资料」同级入口），
                    // 不再埋在资料表单底部 —— 混在一起既容易误填，
                    // 也让人以为「保存资料」会顺带改密码。
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
