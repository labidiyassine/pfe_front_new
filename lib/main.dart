import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:openvpn_flutter/openvpn_flutter.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:async';
import 'dart:ffi' if (dart.library.io) 'dart:io' show Platform;
import 'services/vpn_service.dart';

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

  @override
  void initState() {
    super.initState();
    _initPrefs();
    fetchClients();
    _initVPN();
    _requestNotificationPermission();
    _getCurrentIpAddress();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
  }

  Future<void> _initVPN() async {
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
      });
    };

    _vpnService.onConnectionChanged = (connected) {
      setState(() {
        if (connected && connectedClientId != null) {
          for (var client in clients) {
            if (client.id == connectedClientId) {
              client.connected = true;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Connected to ${client.name}')),
              );
            }
          }
        } else {
          for (var client in clients) {
            client.connected = false;
          }
          connectedClientId = null;
        }
        loading = false;
      });
    };
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

  Future<void> _requestNotificationPermission() async {
    if (Platform.isAndroid) {
      if (await Permission.notification.isDenied) {
        await Permission.notification.request();
      }
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

  Future<void> connectVPN(VPNClient client) async {
    final filePath = await downloadOvpnFile(client);
    if (filePath == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to download .ovpn file')),
      );
      return;
    }

    try {
      setState(() {
        loading = true;
      });
      connectedClientId = client.id;
      
      String config = await File(filePath).readAsString();
      await _vpnService.connect(config, client.name);
      
      // Save connection info
      await _prefs.setString('current_vpn', client.name);
      await _prefs.setString('vpn_config_path', filePath);
      
      // Update IP address
      await _getCurrentIpAddress();
      
    } catch (e) {
      print('Error in connectVPN: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start VPN: $e'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        loading = false;
        client.connected = false;
      });
    }
  }

  Future<void> disconnectVPN(VPNClient client) async {
    setState(() {
      loading = true;
    });
    try {
      await _vpnService.disconnect();
      
      // Clear saved connection info
      await _prefs.remove('current_vpn');
      await _prefs.remove('vpn_config_path');
      
      // Update IP address
      await _getCurrentIpAddress();
      
      await fetchClients();
      
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
    } finally {
      setState(() {
        loading = false;
      });
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
          children: [
            const Expanded(
              child: Text('VPN Clients', overflow: TextOverflow.ellipsis),
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
      body: loading || isAuthenticating
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
              : Column(
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
                          Text(
                            'VPN Status: $status',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: status.toLowerCase().contains('connected')
                                  ? Colors.green
                                  : Colors.red,
                            ),
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
                      child: RefreshIndicator(
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
                                  onChanged: (val) async {
                                    if (val) {
                                      await connectVPN(client);
                                    } else {
                                      await disconnectVPN(client);
                                    }
                                  },
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
    super.dispose();
  }
}