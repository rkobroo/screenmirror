import 'package:flutter/material.dart';

import 'device_tile.dart';

/// A single discovered PC row for the pairing list.
class DeviceList extends StatelessWidget {
  const DeviceList({
    super.key,
    required this.devices,
    required this.onConnect,
  });

  final List<dynamic> devices;
  final void Function(dynamic device) onConnect;

  @override
  Widget build(BuildContext context) {
    if (devices.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32),
        child: Center(
          child: Text('Looking for PCs on this network…'),
        ),
      );
    }
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: devices.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final device = devices[index];
        return DeviceTile(
          name: device.name,
          subtitle: '${device.ip} · tap to connect',
          icon: Icons.computer,
          onTap: () => onConnect(device),
        );
      },
    );
  }
}
