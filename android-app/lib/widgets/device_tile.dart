import 'package:flutter/material.dart';

/// A tappable list tile with an icon and trailing chevron.
class DeviceTile extends StatelessWidget {
  const DeviceTile({
    super.key,
    required this.name,
    required this.subtitle,
    required this.icon,
    this.onTap,
    this.trailing,
  });

  final String name;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(icon, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(subtitle),
        trailing: trailing ??
            (onTap != null
                ? const Icon(Icons.chevron_right)
                : null),
        onTap: onTap,
      ),
    );
  }
}
