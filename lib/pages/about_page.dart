import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/app_info.dart';
import '../core/app_theme.dart';
import '../core/l10n.dart';
import '../widgets/app_logo.dart';

class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(L.t('shareFailed'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    Widget entry({
      required IconData icon,
      required String title,
      String? subtitle,
      VoidCallback? onTap,
    }) {
      return ListTile(
        leading: Icon(icon, size: 20),
        title: Text(title, style: const TextStyle(fontSize: 13.5)),
        subtitle: subtitle == null
            ? null
            : Text(
                subtitle,
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                ),
              ),
        trailing: onTap == null
            ? null
            : const Icon(Icons.chevron_right, size: 18),
        onTap: onTap,
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(L.t('about'))),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          const SizedBox(height: 24),
          Center(
            child: Column(
              children: [
                const AppLogo(size: 84),
                const SizedBox(height: 14),
                Text(
                  'JMoe',
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  L.tp('versionWithProto', {
                    'v': appVersion,
                    'p': appProtocolVersion,
                  }),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              L.t('aboutDesc'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.7,
                color: scheme.onSurface.withValues(alpha: 0.82),
              ),
            ),
          ),
          const SizedBox(height: 20),

          Container(
            margin: const EdgeInsets.symmetric(
              horizontal: AppStyle.pagePadding,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                entry(
                  icon: Icons.code_rounded,
                  title: L.t('aboutRepo'),
                  subtitle: 'github.com/liuyuexiaoyu1/JMoe',
                  onTap: () => _open(
                    context,
                    'https://github.com/liuyuexiaoyu1/JMoe',
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 52,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                entry(
                  icon: Icons.bug_report_outlined,
                  title: L.t('aboutIssues'),
                  subtitle: L.t('aboutIssuesDesc'),
                  onTap: () => _open(
                    context,
                    'https://github.com/liuyuexiaoyu1/JMoe/issues',
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 52,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                entry(
                  icon: Icons.workspace_premium_outlined,
                  title: L.t('aboutAuthor'),
                  subtitle: 'Liuyue_awa',
                ),
                Divider(
                  height: 1,
                  indent: 52,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                entry(
                  icon: Icons.balance_rounded,
                  title: L.t('aboutLicense'),
                  subtitle: 'MIT License',
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),

          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text(
              L.t('aboutThanks'),
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Container(
            margin: const EdgeInsets.symmetric(
              horizontal: AppStyle.pagePadding,
            ),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              children: [
                entry(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Kazumi',
                  subtitle: '界面设计语言参考',
                  onTap: () => _open(
                    context,
                    'https://github.com/Predidit/Kazumi',
                  ),
                ),
                Divider(
                  height: 1,
                  indent: 52,
                  color: scheme.outlineVariant.withValues(alpha: 0.4),
                ),
                entry(
                  icon: Icons.flutter_dash_rounded,
                  title: 'Flutter',
                  subtitle: '跨平台 UI 框架',
                  onTap: () => _open(context, 'https://flutter.dev'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),

          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              L.t('aboutDisclaimer'),
              style: TextStyle(
                fontSize: 11,
                height: 1.7,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
