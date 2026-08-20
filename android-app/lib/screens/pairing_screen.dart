import 'package:flutter/material.dart' hide ConnectionState;

import '../app_services.dart';
import '../models/nearby_device.dart';
import '../services/connection_controller.dart';
import '../widgets/device_list.dart';

/// Pairing flow: shows discovered PCs and lets the user tap to connect
/// directly (no PIN required).
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  static const route = '/pairing';

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _ipController = TextEditingController();
  bool _connecting = false;

  bool _discoveryStarted = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_discoveryStarted) {
      _discoveryStarted = true;
      _startDiscovery();
    }
  }

  Future<void> _startDiscovery() async {
    final services = ServicesScope.of(context);
    await services.controller.startDiscovery();
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  void _connect(NearbyDevice device) async {
    if (_connecting) return;
    setState(() => _connecting = true);
    final services = ServicesScope.of(context);
    await services.controller.connect(device, '000000');
    if (mounted) setState(() => _connecting = false);
    _watchConnection(services);
  }

  void _watchConnection(AppServices services) {
    void check() {
      if (!mounted) return;
      final s = services.controller.state;
      if (s == ConnectionState.streaming || s == ConnectionState.negotiating) {
        Navigator.of(context).pop();
        return;
      }
      if (s == ConnectionState.error) return;
      Future.delayed(const Duration(milliseconds: 500), check);
    }

    check();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Pair Device')),
      body: AnimatedBuilder(
        animation: services.controller,
        builder: (context, _) {
          final controller = services.controller;
          final devices = controller.devices;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (controller.state == ConnectionState.pairing)
                const LinearProgressIndicator(),
              Text('Tap a PC to connect',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _ipController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'PC IP (optional)',
                        counterText: '',
                        prefixIcon: Icon(Icons.router),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    icon: _connecting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.link),
                    label: const Text('Connect'),
                    onPressed: _connecting
                        ? null
                        : () {
                            final manualIp = _ipController.text.trim();
                            if (manualIp.isNotEmpty) {
                              _connect(NearbyDevice(
                                name: 'Manual entry',
                                ip: manualIp,
                                port: 59661,
                              ));
                            }
                          },
                  ),
                ],
              ),
              const SizedBox(height: 24),
              Row(
                children: [
                  Text('Nearby PCs',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                  if (controller.state == ConnectionState.discovering)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    tooltip: 'Rescan for PCs',
                    onPressed: () => controller.refreshDiscovery(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              DeviceList(
                devices: devices,
                onConnect: (device) => _connect(device),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

}
