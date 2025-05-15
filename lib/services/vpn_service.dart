import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class VPNService {
  static final VPNService _instance = VPNService._internal();
  factory VPNService() => _instance;
  VPNService._internal();

  bool _isConnected = false;
  String _status = "Disconnected";
  Function(String)? onStatusChanged;
  Function(bool)? onConnectionChanged;
  Process? _vpnProcess; // For desktop platforms
  StreamSubscription<String>? _stdoutSubscription;
  StreamSubscription<String>? _stderrSubscription;
  String? _openvpnPath;

  bool get isConnected => _isConnected;

  Future<void> initialize() async {
    if (Platform.isAndroid) {
      // On Android we'd initialize the OpenVPN plugin
      // But for now, we're just creating a stub
      print('Initializing VPN for Android');
    } else if (Platform.isWindows || Platform.isLinux) {
      await _extractOpenVPN();
      _status = "Ready to connect";
      onStatusChanged?.call(_status);
    } else {
      // Unsupported platform
      print('Platform ${Platform.operatingSystem} is not supported yet');
    }
  }

  Future<void> _extractOpenVPN() async {
    try {
      // Create directory to store OpenVPN and config files
      final appDir = await getApplicationSupportDirectory();
      final vpnDir = Directory('${appDir.path}/vpn');
      final binDir = Directory('${appDir.path}/vpn/bin');
      final configDir = Directory('${appDir.path}/vpn/config');
      
      if (!await vpnDir.exists()) {
        await vpnDir.create(recursive: true);
      }

      if (!await binDir.exists()) {
        await binDir.create(recursive: true);
      }
      
      if (!await configDir.exists()) {
        await configDir.create(recursive: true);
      }

      // Set the OpenVPN path
    if (Platform.isWindows) {
        _openvpnPath = '${binDir.path}/openvpn.exe';
      } else if (Platform.isLinux) {
        _openvpnPath = '${binDir.path}/openvpn';
      }

      // List of main file to extract - OpenVPN executable
      final String mainFile = Platform.isWindows ? 'openvpn.exe' : 'openvpn';
      
      // Check if the main OpenVPN binary exists
      if (await File('${binDir.path}/$mainFile').exists()) {
        onStatusChanged?.call('OpenVPN binary already exists');
      } else {
        // Extract just the OpenVPN binary from assets
        try {
          onStatusChanged?.call('Extracting OpenVPN binary...');
          
          final String assetPath = Platform.isWindows 
              ? 'assets/vpn_bin/windows/$mainFile' 
              : 'assets/vpn_bin/linux/$mainFile';
          
          final data = await rootBundle.load(assetPath);
          
          final bytes = data.buffer.asUint8List(
            data.offsetInBytes, 
            data.lengthInBytes
          );
          
          final String targetPath = '${binDir.path}/$mainFile';
          await File(targetPath).writeAsBytes(bytes);
          
          if (Platform.isLinux) {
            await Process.run('chmod', ['+x', targetPath]);
          }
          
          onStatusChanged?.call('OpenVPN binary extracted successfully');
        } catch (e) {
          onStatusChanged?.call('Error extracting OpenVPN binary: $e');
          print('Error extracting OpenVPN: $e');
          
          // Try finding an installed OpenVPN as fallback
          _checkForInstalledOpenVPN();
          return;
        }
      }

      // Successfully extracted or found the OpenVPN binary
      _openvpnPath = '${binDir.path}/$mainFile';
    } catch (e) {
      onStatusChanged?.call('Error preparing VPN: $e');
      print('Error preparing OpenVPN: $e');
      
      // Try finding an installed OpenVPN as fallback
      _checkForInstalledOpenVPN();
    }
  }

  Future<void> _checkForInstalledOpenVPN() async {
    // Check common installation paths as a fallback
    final commonPaths = Platform.isWindows
        ? [
            'C:\\Program Files\\OpenVPN\\bin\\openvpn.exe',
            'C:\\Program Files (x86)\\OpenVPN\\bin\\openvpn.exe',
          ]
        : [
            '/usr/sbin/openvpn',
            '/usr/bin/openvpn',
          ];
    
    for (final path in commonPaths) {
      if (await File(path).exists()) {
        _openvpnPath = path;
        onStatusChanged?.call('Found OpenVPN at: $path');
        return;
      }
    }
    
    onStatusChanged?.call('OpenVPN not found. Functionality will be limited.');
  }

  Future<void> connect(String config, String name) async {
    if (Platform.isAndroid) {
      // On Android we'd connect to the VPN
      // But for now, we're just creating a stub
      print('Connecting to VPN on Android: $name');
      _simulateConnection();
    } else if (Platform.isWindows || Platform.isLinux) {
      // Make sure any previous connection is fully disconnected
      if (_isConnected) {
        await disconnect();
        // Add extra delay to ensure TAP adapter is released
        await Future.delayed(const Duration(seconds: 3));
      }
      
      // On Windows/Linux, we'll use the OpenVPN executable
      await _connectWithOpenVPN(config, name);
    } else {
      print('VPN connect not supported on ${Platform.operatingSystem}');
    }
  }

  Future<void> _connectWithOpenVPN(String config, String name) async {
    try {
      // Make sure there's no active connection
      await disconnect();
      
      // Add a short delay to ensure TAP adapter is fully released
      await Future.delayed(const Duration(seconds: 2));
      
      // Check TAP adapter status and try to fix common issues
      await _checkAndFixTapAdapter();
      
      if (_openvpnPath == null || !await File(_openvpnPath!).exists()) {
        onStatusChanged?.call('OpenVPN not available. Please restart the app.');
        return;
      }
      
      onStatusChanged?.call('Starting OpenVPN connection...');
      
      // Save the config to a file
      final appDir = await getApplicationSupportDirectory();
      final configPath = '${appDir.path}/vpn/config/$name.ovpn';
      await File(configPath).writeAsString(config);
      
      // Run OpenVPN with more verbose logging and connection retry options
      final process = await Process.start(
        _openvpnPath!,
        [
          '--config', configPath,
          '--verb', '4',  // More verbose logging
          '--connect-retry', '2', '10',  // Retry connection up to 2 times with 10 second delay
          '--connect-timeout', '30',  // 30 second connection timeout
          '--resolv-retry', '2',  // Retry DNS resolution up to 2 times
          '--data-ciphers', 'AES-256-GCM:AES-128-GCM:AES-128-CBC',
          '--cipher', 'AES-128-CBC',
          '--persist-tun',  // Keep tun device between restarts
          '--persist-key'   // Keep keys between restarts
        ],
        runInShell: true,
        mode: ProcessStartMode.normal,
      );
      
      _vpnProcess = process;
      
      // Handle process output
      _stdoutSubscription = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            print('OpenVPN stdout: $line');
            _handleOpenVPNOutput(line);
          });
      
      _stderrSubscription = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            print('OpenVPN stderr: $line');
            _handleOpenVPNOutput(line);
          });
      
      // Set a timeout for connection
      Future.delayed(const Duration(seconds: 60), () {
        if (!_isConnected && _vpnProcess != null) {
          onStatusChanged?.call('Connection timed out after 60 seconds');
          disconnect();
        }
      });
      
      // Monitor process exit
      process.exitCode.then((exitCode) {
        print('OpenVPN exited with code: $exitCode');
        if (exitCode != 0) {
          onStatusChanged?.call('OpenVPN process failed with exit code: $exitCode');
        }
        if (_isConnected) {
          _isConnected = false;
          onStatusChanged?.call('Disconnected (process exited)');
          onConnectionChanged?.call(false);
        }
      });
      
    } catch (e) {
      onStatusChanged?.call('Error connecting: $e');
      print('Error connecting with OpenVPN: $e');
      _isConnected = false;
      onConnectionChanged?.call(false);
    }
  }

  void _handleOpenVPNOutput(String line) {
    // Update status based on OpenVPN output
    _status = line;
    onStatusChanged?.call(line);
    
    final lowerLine = line.toLowerCase();
    
    // Look for successful connection
    if (lowerLine.contains('initialization sequence completed')) {
      _isConnected = true;
      _status = 'Connected';
      onStatusChanged?.call(_status);
      onConnectionChanged?.call(true);
    }
    // Look for connection attempts
    else if (lowerLine.contains('tcp') || lowerLine.contains('udp')) {
      if (lowerLine.contains('connecting')) {
        onStatusChanged?.call('Attempting connection...');
      }
    }
    // Look for permission issues
    else if ((lowerLine.contains('access denied') || lowerLine.contains('accès refusé')) && 
             (lowerLine.contains('route') || lowerLine.contains('tap'))) {
      onStatusChanged?.call('ADMIN RIGHTS REQUIRED: Run the app as administrator to enable routing');
      // Still count as connected since the VPN tunnel is established, just routing may be incomplete
      if (!_isConnected) {
        _isConnected = true;
        onConnectionChanged?.call(true);
      }
    }
    // Also count successful TUN/TAP interface setup as connection progress
    else if (lowerLine.contains('add_route') || 
             lowerLine.contains('ip address added') ||
             lowerLine.contains('dhcp option') || 
             lowerLine.contains('ifconfig')) {
      onStatusChanged?.call('Setting up network...');
    }
    // Look for connection errors
    else if (lowerLine.contains('error') || 
             lowerLine.contains('fatal') ||
             lowerLine.contains('cannot') ||
             lowerLine.contains('failed')) {
      // Don't mark as disconnected on common warnings
      if (!lowerLine.contains('warning') && 
          !_isConnected &&
          !lowerLine.contains('deprecated')) {
        onStatusChanged?.call('Error: $line');
        // If we get a fatal error, ensure we're marked as disconnected
        if (lowerLine.contains('fatal')) {
          _isConnected = false;
          onConnectionChanged?.call(false);
        }
      }
    }
  }

  void _simulateConnection() {
    // Simulate VPN connection for testing (Android)
    onStatusChanged?.call('Connecting...');
    
    Future.delayed(const Duration(milliseconds: 500), () {
      onStatusChanged?.call('Authenticating...');
    });
    
    Future.delayed(const Duration(seconds: 1), () {
      onStatusChanged?.call('Establishing connection...');
    });
    
    Future.delayed(const Duration(seconds: 2), () {
      _isConnected = true;
      _status = "Connected";
      onStatusChanged?.call(_status);
      onConnectionChanged?.call(true);
    });
  }

  Future<void> disconnect() async {
    // Cancel any subscriptions first to prevent callbacks during disconnection
    if (_stdoutSubscription != null) {
      await _stdoutSubscription!.cancel();
      _stdoutSubscription = null;
    }
    
    if (_stderrSubscription != null) {
      await _stderrSubscription!.cancel();
      _stderrSubscription = null;
    }
    
    // Update status immediately to reflect disconnect is happening
    onStatusChanged?.call('Disconnecting...');
    
    if (Platform.isAndroid) {
      // On Android we'd disconnect from the VPN
      // But for now, we're just creating a stub
      print('Disconnecting from VPN on Android');
      _simulateDisconnection();
    } else if (Platform.isWindows) {
      // On Windows, we need to forcefully kill all OpenVPN processes
      try {
        // Kill all OpenVPN processes - most reliable method
        final killResult = await Process.run('taskkill', ['/F', '/IM', 'openvpn.exe'], runInShell: true);
        print('Kill all openvpn.exe result: ${killResult.stdout} ${killResult.stderr}');
        
        // Also try to kill by our specific process ID if we have one
        if (_vpnProcess != null) {
          try {
            _vpnProcess!.kill(ProcessSignal.sigkill);
            print('Killed specific VPN process');
          } catch (e) {
            print('Error killing specific process: $e');
          }
        }
        
        // Reset network connections to clear any VPN state
        print('Resetting network connections');
        try {
          await Process.run('ipconfig', ['/release'], runInShell: true);
          await Future.delayed(const Duration(seconds: 1));
          await Process.run('ipconfig', ['/renew'], runInShell: true);
        } catch (e) {
          print('Error resetting network: $e');
        }
        
        _vpnProcess = null;
        _isConnected = false;
        _status = "Disconnected";
        onConnectionChanged?.call(false);
        onStatusChanged?.call(_status);
        
      } catch (e) {
        print('Error during Windows VPN disconnection: $e');
        // Ensure we reset state even on error
        _isConnected = false;
        _status = "Disconnected";
        onConnectionChanged?.call(false);
        onStatusChanged?.call('Disconnected with errors');
      }
    } else if (Platform.isLinux) {
      // For Linux
      try {
        await Process.run('killall', ['-9', 'openvpn'], runInShell: true);
        
        if (_vpnProcess != null) {
          try {
            _vpnProcess!.kill(ProcessSignal.sigkill);
    } catch (e) {
            print('Error killing Linux process: $e');
          }
        }
        
        _vpnProcess = null;
        _isConnected = false;
        _status = "Disconnected";
        onConnectionChanged?.call(false);
        onStatusChanged?.call(_status);
        
      } catch (e) {
        print('Error during Linux VPN disconnection: $e');
        _isConnected = false;
        onConnectionChanged?.call(false);
        onStatusChanged?.call('Disconnected with errors');
      }
    } else {
      print('VPN disconnect not supported on ${Platform.operatingSystem}');
    }
    
    // Allow TAP adapter to be fully released
    await Future.delayed(const Duration(seconds: 3));
  }

  void _simulateDisconnection() {
    // Simulate VPN disconnection for Android
    onStatusChanged?.call('Disconnecting...');
    
    Future.delayed(const Duration(milliseconds: 500), () {
      _isConnected = false;
      _status = "Disconnected";
      onStatusChanged?.call(_status);
      onConnectionChanged?.call(false);
    });
  }

  String get status => _status;

  void dispose() {
    disconnect();
  }

  // Try to check and fix common TAP adapter issues
  Future<void> _checkAndFixTapAdapter() async {
    if (Platform.isWindows) {
      try {
        // Check if the TAP Windows Adapter service is running
        final result = await Process.run('sc', ['query', 'tap0901'], runInShell: true);
        final output = result.stdout.toString().toLowerCase();
        
        if (output.contains('stopped') || output.contains('disabled')) {
          onStatusChanged?.call('TAP adapter service is not running. Trying to start it...');
          
          // Try to start the service
          await Process.run('net', ['start', 'tap0901'], runInShell: true);
          await Future.delayed(const Duration(seconds: 1));
        }
        
        // Reset any stuck TAP adapter instances
        await Process.run('netsh', ['interface', 'set', 'interface', 'name="TAP-Windows Adapter V9"', 'admin=disabled'], runInShell: true);
        await Future.delayed(const Duration(milliseconds: 500));
        await Process.run('netsh', ['interface', 'set', 'interface', 'name="TAP-Windows Adapter V9"', 'admin=enabled'], runInShell: true);
        
      } catch (e) {
        // This will likely fail without admin rights, but we tried
        print('Error checking/fixing TAP adapter: $e');
      }
    }
  }
}