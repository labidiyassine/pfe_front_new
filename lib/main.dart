import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
// Conditionally import OpenVPN for Android only
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:ffi';
import 'services/vpn_service.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VPN Client',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      home: const VPNClientListPage(),
    );
  }
}

class VPNClient {
  final int id;
  final String name;
  bool connected;
  VPNClient({required this.id, required this.name, required this.connected});

  factory VPNClient.fromJson(Map<String, dynamic> json) {
    return VPNClient(
      id: json['id'],
      name: json['name'],
      connected: json['connected'],
    );
  }
}

class VPNClientListPage extends StatefulWidget {
  const VPNClientListPage({super.key});

  @override
  State<VPNClientListPage> createState() => _VPNClientListPageState();
}

class _VPNClientListPageState extends State<VPNClientListPage> {
  final String backendUrl = 'http://192.168.1.12:8000';
  List<VPNClient> clients = [];
  bool loading = false;
  String status = "Disconnected";
  String stage = "Idle";
  int? connectedClientId;
  bool isAuthenticating = false;
  late SharedPreferences _prefs;
  final NetworkInfo _networkInfo = NetworkInfo();
  String? _currentIpAddress;
  final VPNService _vpnService = VPNService();
  bool _isPlatformSupported = true;
  Timer? _ipRefreshTimer;

  @override
  void initState() {
    super.initState();
    _initPrefs();
    _initVPN();
    _requestPermissions();
    _getCurrentIpAddress();
    fetchClients();
    
    // Start IP refresh timer
    _ipRefreshTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
      if (_vpnService.isConnected) {
        _getCurrentIpAddress();
      }
      
      // Also periodically sync connection states
      _syncConnectionStates();
    });
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> _initVPN() async {
    try {
      if (!Platform.isAndroid && !Platform.isWindows && !Platform.isLinux) {
        setState(() {
          _isPlatformSupported = false;
          status = "Platform not supported";
        });
        return;
      }
      
      await _vpnService.initialize();
      
      _vpnService.onStatusChanged = (status) {
        setState(() {
          this.status = status;
          if (status.toLowerCase().contains('authenticat')) {
            isAuthenticating = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Authenticating...')),
            );
          } else {
            isAuthenticating = false;
          }
          
          // Check for TAP adapter errors
          if (status.toLowerCase().contains('tap') && 
              (status.toLowerCase().contains('in use') || 
               status.toLowerCase().contains('disabled') ||
               status.toLowerCase().contains('failure'))) {
            
            // Show a more specific message for TAP adapter issues
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('TAP adapter issue detected. Try restarting the app with admin rights.'),
                duration: const Duration(seconds: 10),
                action: SnackBarAction(
                  label: 'Dismiss',
                  onPressed: () {
                    ScaffoldMessenger.of(context).hideCurrentSnackBar();
                  },
                ),
              ),
            );
            
            // Reset connection state and UI
            _resetConnectionState();
          }
          
          // Check for errors in status that might indicate a failed connection
          if ((status.toLowerCase().contains('error') || 
               status.toLowerCase().contains('failed') ||
               status.toLowerCase().contains('critical')) &&
              !status.toLowerCase().contains('warning')) {
            // If we detect a serious error, sync the states to ensure UI accurately reflects it
            _syncConnectionStates();
          }
        });
      };
      
      _vpnService.onConnectionChanged = (connected) {
        setState(() {
          loading = false;
          status = connected ? "Connected" : "Disconnected";
          
          // Update all clients to reflect the current connection state
          for (var client in clients) {
            // If we're connected, only the selected client should show as connected
            if (connected && client.id == connectedClientId) {
              client.connected = true;
            } else {
              client.connected = false;
            }
          }
          
          // If we're disconnected, clear the connected client ID
          if (!connected) {
            connectedClientId = null;
          }
        });
      };
      
    } catch (e) {
      print('VPN initialization error: $e');
      
      // Handle initialization errors differently on Windows/Linux
      if (Platform.isWindows || Platform.isLinux) {
        setState(() {
          status = "Limited functionality on ${Platform.operatingSystem}";
        });
        
        // Only show dialog for severe errors
        if (e.toString().contains('critical') || 
            e.toString().contains('permission')) {
          _showError('VPN Setup Error', e.toString());
        }
      } else {
        _showError('Error', e.toString());
      }
    }
  }
  
  void _showError(String title, String message) {
    // Use Future.microtask to avoid showing dialog during build
    Future.microtask(() {
      if (mounted) {
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
              title: Text(title),
              content: Text(message),
            actions: [
              TextButton(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          );
        },
      );
    }
    });
  }

  Future<void> _requestPermissions() async {
    if (Platform.isAndroid) {
      await Permission.notification.request();
    }
  }

  Future<void> _getCurrentIpAddress() async {
    try {
      final ip = await _networkInfo.getWifiIP();
      setState(() {
        _currentIpAddress = ip;
      });
    } catch (e) {
      print('Error getting IP address: $e');
    }
  }

  Future<void> fetchClients() async {
    setState(() => loading = true);
    try {
      final response = await http.get(Uri.parse('${backendUrl}/api/vpn_connect/configs/'));
      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);
        setState(() {
          clients = data.map((e) => VPNClient.fromJson(e)).toList();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to fetch clients')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error fetching clients: $e')),
      );
    } finally {
      setState(() => loading = false);
    }
  }

  Future<String?> downloadOvpnFile(VPNClient client) async {
    try {
      final response = await http.get(Uri.parse('${backendUrl}/api/vpn_connect/configs/${client.id}/'));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final content = data['content'];
        final dir = await getApplicationDocumentsDirectory();
        final filePath = '${dir.path}/${client.name}.ovpn';
        final file = File(filePath);
        await file.writeAsString(content);
        return filePath;
      }
      return null;
    } catch (e) {
      print('Error downloading OVPN file: $e');
      return null;
    }
  }

  // Reset connection state after errors
  void _resetConnectionState() {
    setState(() {
      loading = false;
      status = "Disconnected";
      
      // Update all clients to show as disconnected
      for (var client in clients) {
        client.connected = false;
      }
      
      connectedClientId = null;
    });
  }

  // Synchronize UI toggle states with actual VPN connection state
  void _syncConnectionStates() {
    // If loading, don't try to sync states to avoid UI flicker
    if (loading) return;
    
    bool vpnConnected = _vpnService.isConnected;
    
    setState(() {
      // Update the global status indicator
      if (vpnConnected) {
        status = "Connected";
        
        // If VPN is connected but no client is marked as connected,
        // try to find the last connected client from preferences
        if (connectedClientId == null) {
          String? lastVpn = _prefs.getString('current_vpn');
          if (lastVpn != null) {
            for (var client in clients) {
              if (client.name == lastVpn) {
                connectedClientId = client.id;
                client.connected = true;
                break;
              }
            }
          }
        }
      } else if (!status.contains("Error") && !status.contains("Failed") &&
                !status.contains("TAP")) {  // Don't override error messages
        status = "Disconnected";
        // Reset all clients to disconnected state
        for (var client in clients) {
          client.connected = false;
        }
        connectedClientId = null;
      }
      
      // Make sure toggle states match the connection state
      bool foundConnectedClient = false;
      for (var client in clients) {
        if (vpnConnected && client.id == connectedClientId) {
          client.connected = true;
          foundConnectedClient = true;
        } else {
          client.connected = false;
        }
      }
      
      // If VPN is connected but no client is marked as connected, force disconnect
      if (vpnConnected && !foundConnectedClient) {
        _vpnService.disconnect();
      }
    });
  }

  Future<void> connectVPN(VPNClient client) async {
    try {
      setState(() {
        loading = true;
        status = "Connecting...";
      });
      
      // First disconnect any existing connection
      if (_vpnService.isConnected) {
        await _vpnService.disconnect();
      }
      
      final filePath = await downloadOvpnFile(client);
      if (filePath == null) {
        throw Exception('Failed to download .ovpn file');
      }
  
      // Set this client as the one being connected
      connectedClientId = client.id;

      // Update UI to show this client is being connected
      setState(() {
        for (var c in clients) {
          c.connected = c.id == client.id;
        }
      });
      
      String config = await File(filePath).readAsString();
      
      await _vpnService.connect(config, client.name);
      
      // Save connection info
      await _prefs.setString('current_vpn', client.name);
      await _prefs.setString('vpn_config_path', filePath);
      
      // Wait a moment before refreshing IP to allow connection to establish
      if (_vpnService.isConnected) {
        await Future.delayed(const Duration(seconds: 5));
        await _getCurrentIpAddress();
      }
      
      // Make sure UI is in sync with connection state
      _syncConnectionStates();
      
    } catch (e) {
      print('Error in connectVPN: $e');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Connection failed: ${e.toString()}'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Dismiss',
            onPressed: () {
              ScaffoldMessenger.of(context).hideCurrentSnackBar();
            },
          ),
        ),
      );
      
      setState(() {
        loading = false;
        // Reset connection status for all clients
        for (var c in clients) {
          c.connected = false;
        }
        connectedClientId = null;
        status = "Connection failed";
      });
      
      // Make sure UI is in sync with connection state
      _syncConnectionStates();
    }
  }

  Future<void> disconnectVPN(VPNClient client) async {
    // If we're already disconnecting, don't try again
    if (status.toLowerCase() == "disconnecting...") {
      return;
    }
    
    // If client isn't actually shown as connected, fix the state instead of doing a disconnect
    if (!client.connected) {
      _syncConnectionStates();
      return;
    }
    
    setState(() {
      loading = true;
      status = "Disconnecting...";
    });
    
    try {
      await _vpnService.disconnect();
      
      // Clear saved connection info
      await _prefs.remove('current_vpn');
      await _prefs.remove('vpn_config_path');
      
      // Update IP address after a short delay
      await Future.delayed(const Duration(seconds: 3));
      await _getCurrentIpAddress();
      
      setState(() {
        // Ensure all clients show as disconnected
        for (var c in clients) {
          c.connected = false;
        }
        connectedClientId = null;
        status = "Disconnected";
      });
      
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Successfully disconnected'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      print('Error disconnecting VPN: $e');
      
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to stop VPN: $e'),
          backgroundColor: Colors.red,
        ),
      );
      
      // Even if disconnect fails, update UI to show disconnected
      _resetConnectionState();
      
      // Refresh client list to make sure UI is in sync
      fetchClients();
    } finally {
      setState(() {
        loading = false;
      });
      
      // Make sure UI is in sync with connection state
      _syncConnectionStates();
    }
  }

  Future<void> uploadOvpnFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
      );
      if (result != null && result.files.single.path != null) {
        if (result.files.single.path!.endsWith('.ovpn')) {
          setState(() => loading = true);
          
          final file = result.files.single;
          
          if (file.path == null) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Could not get file path')),
            );
            setState(() => loading = false);
            return;
          }

          // Read file as bytes from the path
          final bytes = await File(file.path!).readAsBytes();
          
          // Create multipart request
          final request = http.MultipartRequest(
            'POST',
            Uri.parse('${backendUrl}/api/vpn_connect/upload/'),
          );

          // Add file to request
          request.files.add(
            http.MultipartFile.fromBytes(
              'ovpn_file',
              bytes,
              filename: file.name,
            ),
          );

          // Send request
          final response = await request.send();
          final responseData = await response.stream.bytesToString();

          if (response.statusCode == 200) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('File uploaded successfully')),
            );
            // Refresh the client list
            fetchClients();
          } else {
            print('Upload failed with status ${response.statusCode}: $responseData');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to upload file: ${jsonDecode(responseData)['error'] ?? 'Unknown error'}')),
            );
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select a .ovpn file')),
          );
        }
      }
    } catch (e) {
      print('Error uploading file: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error uploading file: $e')),
      );
    } finally {
      setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Expanded(
              child: Text(
                'VPN Clients',
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: fetchClients,
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: uploadOvpnFile,
        tooltip: 'Upload .ovpn file',
        child: const Icon(Icons.upload_file),
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(8.0),
            color: status.toLowerCase().contains('connected') 
                ? Colors.green.withOpacity(0.2) 
                : Colors.red.withOpacity(0.2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  status.toLowerCase().contains('connected')
                      ? Icons.vpn_lock
                      : Icons.vpn_lock_outlined,
                  color: status.toLowerCase().contains('connected')
                      ? Colors.green
                      : Colors.red,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'VPN Status: $status',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: status.toLowerCase().contains('connected')
                          ? Colors.green
                          : Colors.red,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (status.toLowerCase().contains('connected'))
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: _getCurrentIpAddress,
                    tooltip: 'Refresh IP',
                    color: Colors.green,
                ),
              ],
            ),
          ),
          if (_currentIpAddress != null)
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Text(
                'Current IP: $_currentIpAddress',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : clients.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'No VPN clients found',
                              style: TextStyle(fontSize: 18),
                            ),
                            const SizedBox(height: 20),
                            ElevatedButton.icon(
                              onPressed: uploadOvpnFile,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('Upload .ovpn file'),
                            ),
                          ],
                        ),
                      )
                    : RefreshIndicator(
                        onRefresh: fetchClients,
                        child: ListView.builder(
                          itemCount: clients.length,
                          itemBuilder: (context, index) {
                            final client = clients[index];
                            return Card(
                              margin: const EdgeInsets.symmetric(
                                horizontal: 8.0,
                                vertical: 4.0,
                              ),
                              child: ListTile(
                                title: Text(client.name),
                                subtitle: Text(client.connected ? 'Connected' : 'Disconnected'),
                                trailing: Switch(
                                  value: client.connected,
                                  // Disable the switch during loading state or for other clients when one is connected
                                  onChanged: loading || (connectedClientId != null && connectedClientId != client.id && !client.connected) 
                                    ? null 
                                    : (val) async {
                                        if (val) {
                                          await connectVPN(client);
                                        } else {
                                          await disconnectVPN(client);
                                        }
                                      },
                                  activeColor: loading ? Colors.grey : Colors.green,
                                  inactiveThumbColor: loading ? Colors.grey : null,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _vpnService.disconnect();
    _ipRefreshTimer?.cancel();
    super.dispose();
  }
}