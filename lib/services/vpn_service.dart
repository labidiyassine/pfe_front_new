import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';

class VPNService {
  static final VPNService _instance = VPNService._internal();
  factory VPNService() => _instance;
  VPNService._internal();

  late OpenVPN _androidVpn;
  Process? _vpnProcess;
  bool _isConnected = false;
  String _status = "Disconnected";
  Function(String)? onStatusChanged;
  Function(bool)? onConnectionChanged;
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;

  String get _binaryName {
    if (Platform.isWindows) return 'openvpn.exe';
    if (Platform.isLinux) return 'openvpn';
    throw Exception('Unsupported platform');
  }

  String get _binaryPath {
    if (Platform.isWindows) return 'assets/vpn_bin/windows/$_binaryName';
    if (Platform.isLinux) return 'assets/vpn_bin/linux/$_binaryName';
    throw Exception('Unsupported platform');
  }

  Future<void> initialize() async {
    if (Platform.isAndroid) {
      _initAndroidVPN();
    } else {
      await _extractVPNBinaries();
    }
  }

  void _initAndroidVPN() {
    _androidVpn = OpenVPN(
      onVpnStatusChanged: _handleAndroidStatus,
      onVpnStageChanged: (stage, raw) {
        print('VPN Stage: $stage, Raw: $raw');
      },
    );
    _androidVpn.initialize();
  }

  void _handleAndroidStatus(dynamic status) {
    final statusStr = status?.toString().toLowerCase() ?? "unknown";
    _status = status?.toString() ?? "Unknown";
    
    if (statusStr.contains('connected')) {
      _isConnected = true;
      onConnectionChanged?.call(true);
    } else if (statusStr.contains('disconnected')) {
      _isConnected = false;
      onConnectionChanged?.call(false);
    }
    
    onStatusChanged?.call(_status);
  }

  Future<void> _extractVPNBinaries() async {
    if (Platform.isLinux || Platform.isWindows) {
      final appDir = await getApplicationSupportDirectory();
      final binDir = Directory('${appDir.path}/vpn_bin');
      
      if (!await binDir.exists()) {
        await binDir.create(recursive: true);
        
        final binaryPath = '${binDir.path}/$_binaryName';
        
        if (!await File(binaryPath).exists()) {
          try {
            final byteData = await rootBundle.load(_binaryPath);
            final buffer = byteData.buffer;
            await File(binaryPath).writeAsBytes(
              buffer.asUint8List(byteData.offsetInBytes, byteData.lengthInBytes)
            );
            
            // Make binary executable on Linux
            if (Platform.isLinux) {
              await Process.run('chmod', ['+x', binaryPath]);
            }
          } catch (e) {
            print('Error extracting OpenVPN binary: $e');
            if (Platform.isLinux) {
              // If extraction fails on Linux, try to use system OpenVPN
              final systemOpenvpn = await Process.run('which', ['openvpn']);
              if (systemOpenvpn.exitCode == 0) {
                await File(systemOpenvpn.stdout.toString().trim()).copy(binaryPath);
                await Process.run('chmod', ['+x', binaryPath]);
              } else {
                throw Exception('Failed to extract or find OpenVPN binary');
              }
            } else {
              rethrow;
            }
          }
        }
      }
    }
  }

  Future<void> connect(String config, String name) async {
    if (Platform.isAndroid) {
      await _androidVpn.connect(
        config,
        name,
        username: null,
        password: null,
        certIsRequired: true,
      );
    } else if (Platform.isLinux || Platform.isWindows) {
      final appDir = await getApplicationSupportDirectory();
      final binDir = '${appDir.path}/vpn_bin';
      final configPath = '${appDir.path}/$name.ovpn';
      
      // Write config to file
      await File(configPath).writeAsString(config);
      
      try {
        // Kill any existing OpenVPN processes
        if (Platform.isLinux) {
          try {
            await Process.run('pkill', ['-f', 'openvpn']);
            await Future.delayed(const Duration(seconds: 1));
          } catch (_) {}
        }
        
        // Start OpenVPN process
        final command = Platform.isLinux ? 'sudo' : '${binDir}\\$_binaryName';
        final args = Platform.isLinux 
            ? ['${binDir}/openvpn', '--config', configPath, '--data-ciphers', 'AES-128-CBC:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305']
            : ['--config', configPath, '--data-ciphers', 'AES-128-CBC:AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305'];
            
        _vpnProcess = await Process.start(
          command,
          args,
          mode: ProcessStartMode.normal,
        );
        
        // Cancel any existing subscriptions
        await _stdoutSubscription?.cancel();
        await _stderrSubscription?.cancel();
        
        try {
          // Listen to stdout with proper encoding
          _stdoutSubscription = _vpnProcess!.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (data) => _handleProcessOutput(data),
                onError: (error) {
                  print('Error in stdout stream: $error');
                  _handleProcessOutput('Error: $error');
                },
              );
          
          // Listen to stderr with proper encoding
          _stderrSubscription = _vpnProcess!.stderr
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .listen(
                (data) => _handleProcessOutput(data),
                onError: (error) {
                  print('Error in stderr stream: $error');
                  _handleProcessOutput('Error: $error');
                },
              );
          
          // Wait longer to check if process started successfully
          await Future.delayed(const Duration(seconds: 5));
          
          if (_vpnProcess != null) {
            if (Platform.isLinux) {
              final pidFile = File('/run/openvpn.$name.pid');
              if (await pidFile.exists()) {
                final pid = int.tryParse(await pidFile.readAsString());
                if (pid != null) {
                  final psResult = await Process.run('ps', ['-p', pid.toString()]);
                  if (psResult.exitCode == 0) {
                    _isConnected = true;
                    onConnectionChanged?.call(true);
                    onStatusChanged?.call('Connected');
                    return;
                  }
                }
              }
              
              // If we get here on Linux, check the process directly
              try {
                final exitCode = await _vpnProcess!.exitCode.timeout(
                  const Duration(milliseconds: 100),
                  onTimeout: () => -1,
                );
                if (exitCode == -1) {
                  _isConnected = true;
                  onConnectionChanged?.call(true);
                  onStatusChanged?.call('Connected');
                  return;
                }
              } catch (_) {
                // Process is still running
                _isConnected = true;
                onConnectionChanged?.call(true);
                onStatusChanged?.call('Connected');
                return;
              }
            } else {
              // For Windows, check if the process is still running
              try {
                final exitCode = await _vpnProcess!.exitCode.timeout(
                  const Duration(milliseconds: 100),
                  onTimeout: () => -1,
                );
                if (exitCode == -1) {
                  _isConnected = true;
                  onConnectionChanged?.call(true);
                  onStatusChanged?.call('Connected');
                  return;
                }
              } catch (_) {
                // If we get here, the process is still running
                _isConnected = true;
                onConnectionChanged?.call(true);
                onStatusChanged?.call('Connected');
                return;
              }
            }
          }
        } catch (e) {
          print('Error setting up process streams: $e');
          throw Exception('Failed to setup VPN process streams: $e');
        }
      } catch (e) {
        print('Error starting VPN process: $e');
        _isConnected = false;
        onConnectionChanged?.call(false);
        onStatusChanged?.call('Failed to connect: $e');
        rethrow;
      }
    } else {
      throw Exception('Platform not supported yet');
    }
  }

  void _handleProcessOutput(String data) {
    print('VPN Output: $data');
    _status = data;
    onStatusChanged?.call(data);
    
    final lowerData = data.toLowerCase();
    if (lowerData.contains('initialization sequence completed')) {
      _isConnected = true;
      onConnectionChanged?.call(true);
    } else if (lowerData.contains('process exiting') || 
               lowerData.contains('connection reset') ||
               lowerData.contains('connection refused') ||
               lowerData.contains('auth failed')) {
      _isConnected = false;
      onConnectionChanged?.call(false);
    }
  }

  Future<void> disconnect() async {
    if (Platform.isAndroid) {
      _androidVpn.disconnect();
    } else if (Platform.isLinux || Platform.isWindows) {
      try {
        // Cancel stream subscriptions
        await _stdoutSubscription?.cancel();
        await _stderrSubscription?.cancel();
        _stdoutSubscription = null;
        _stderrSubscription = null;
        
        // Try to kill the process directly first
        if (_vpnProcess != null) {
          _vpnProcess!.kill();
          _vpnProcess = null;
        }
        
        // Then make sure all OpenVPN processes are killed
        if (Platform.isLinux) {
          await Process.run('sudo', ['pkill', '-f', 'openvpn']);
        } else if (Platform.isWindows) {
          await Process.run('taskkill', ['/F', '/IM', _binaryName]);
        }
        
        // Clean up any leftover files
        final appDir = await getApplicationSupportDirectory();
        final configFiles = Directory(appDir.path)
            .listSync()
            .where((f) => f.path.endsWith('.ovpn'))
            .map((f) => f as File);
            
        for (var file in configFiles) {
          try {
            await file.delete();
          } catch (_) {}
        }
      } catch (e) {
        print('Error killing VPN process: $e');
      }
      _isConnected = false;
      onConnectionChanged?.call(false);
      onStatusChanged?.call('Disconnected');
    }
  }

  bool get isConnected => _isConnected;
  String get status => _status;

  void dispose() {
    _stdoutSubscription?.cancel();
    _stderrSubscription?.cancel();
    disconnect();
  }
} 