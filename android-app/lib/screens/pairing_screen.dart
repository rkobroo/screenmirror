import 'dart:async';

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:mobile_scanner/mobile_scanner.dart';

import '../app_services.dart';
import '../models/nearby_device.dart';
import '../services/connection_controller.dart';
import '../widgets/device_list.dart';

/// Pairing flow: shows discovered PCs, lets the user scan a QR code from the
/// PC app, or enter the 6-digit pairing code manually.
class PairingScreen extends StatefulWidget {
  const PairingScreen({super.key});

  static const route = '/pairing';

  @override
  State<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends State<PairingScreen> {
  final _codeController = TextEditingController();
  final _ipController = TextEditingController();
  StreamSubscription<NearbyDevice>? _devicesSub;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _startDiscovery();
  }

  Future<void> _startDiscovery() async {
    final services = ServicesScope.of(context);
    await services.controller.startDiscovery();
  }

  @override
  void dispose() {
    _devicesSub?.cancel();
    _codeController.dispose();
    _ipController.dispose();
    super.dispose();
  }

  void _connect(NearbyDevice device) async {
    if (_connecting) return;
    final code = _codeController.text.trim();
    if (code.length != 6) {
      _showError('Enter the 6-digit code shown on the PC.');
      return;
    }
    setState(() => _connecting = true);
    final services = ServicesScope.of(context);
    await services.controller.connect(device, code);
    if (mounted) setState(() => _connecting = false);
    _navigateWhenConnected(services);
  }

  void _navigateWhenConnected(AppServices services) {
    // Move home once streaming (or show the error inline).
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (services.controller.state == ConnectionState.streaming ||
          services.controller.state == ConnectionState.negotiating) {
        Navigator.of(context).pop();
      }
    });
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
              Text('Enter pairing code',
                  style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _codeController,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      decoration: const InputDecoration(
                        labelText: '6-digit code',
                        counterText: '',
                        prefixIcon: Icon(Icons.pin),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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
                ],
              ),
              const SizedBox(height: 12),
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
                        final base = devices.isNotEmpty
                            ? devices.first
                            : NearbyDevice(
                                name: 'Manual entry',
                                ip: manualIp.isEmpty ? '192.168.1.100' : manualIp,
                                port: 59661,
                              );
                        if (manualIp.isNotEmpty) {
                          _connect(NearbyDevice(
                            name: 'Manual entry',
                            ip: manualIp,
                            port: 59661,
                          ));
                        } else {
                          _connect(base);
                        }
                      },
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
                ],
              ),
              const SizedBox(height: 8),
              DeviceList(
                devices: devices,
                onConnect: (device) => _connect(device),
              ),
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Text('Scan QR from PC',
                      style: Theme.of(context).textTheme.titleSmall),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 220,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: MobileScanner(
                    onDetect: (capture) {
                      final raw = capture.barcodes
                          .map((b) => b.rawValue)
                          .whereType<String>()
                          .firstOrNull;
                      if (raw == null) return;
                      _handleQrPayload(raw);
                    },
                    errorBuilder: (context, error, child) => Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.camera_alt_outlined, size: 40),
                          const SizedBox(height: 8),
                          Text('Camera unavailable'),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          );
        },
      ),
    );
  }

  /// Parse `mirrorlink://pair?ip=..&port=..&code=..` and connect.
  void _handleQrPayload(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null || uri.host != 'pair') return;

    final ip = uri.queryParameters['ip'];
    final port = int.tryParse(uri.queryParameters['port'] ?? '') ?? 59661;
    final code = uri.queryParameters['code'];
    if (ip == null || code == null) return;

    _codeController.text = code;
    _connect(NearbyDevice(name: 'QR device', ip: ip, port: port));
  }
}
