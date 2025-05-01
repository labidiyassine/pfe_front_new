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
  final String backendUrl = 'http://192.168.1.15:8000';
  List<VPNClient> clients = [];
  bool loading = false;
  late OpenVPN openvpn;
  String status = "Disconnected";
  String stage = "Idle";
  int? connectedClientId;
  Timer? _authTimer;
  bool isAuthenticating = false;
  String? pendingUsername;
  String? pendingPassword;
  late SharedPreferences _prefs;
  final NetworkInfo _networkInfo = NetworkInfo();
  String? _currentIpAddress;

  @override
  void initState() {
    super.initState();
    _initPrefs();
    fetchClients();
    if (Platform.isAndroid) {
      _initAndroidVPN();
    }
    _requestNotificationPermission();
    _getCurrentIpAddress();
  }

  Future<void> _initPrefs() async {
    _prefs = await SharedPreferences.getInstance();
  }

  void _initAndroidVPN() {
    openvpn = OpenVPN(
      onVpnStatusChanged: (data) {
        print('Raw VPN Status: $data');
        setState(() {
          status = data?.toString() ?? "Unknown";
          final statusStr = status.toLowerCase();
          
          if (statusStr.contains('authenticat')) {
            isAuthenticating = true;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Authenticating...')),
            );
          } else {
            isAuthenticating = false;
          }

          if (statusStr.contains('connected')) {
            if (connectedClientId != null) {
              for (var client in clients) {
                if (client.id == connectedClientId) {
                  client.connected = true;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Connected to ${client.name}')),
                  );
                }
              }
            }
            setState(() => loading = false);
          } else if (statusStr.contains('disconnected')) {
            for (var client in clients) {
              client.connected = false;
            }
            connectedClientId = null;
            setState(() => loading = false);
          }

          if (statusStr.contains('auth failed') || 
              statusStr.contains('auth-failure')) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Authentication failed. Please check your username and password.'),
                backgroundColor: Colors.red,
              ),
            );
            setState(() {
              loading = false;
              isAuthenticating = false;
              for (var client in clients) {
                client.connected = false;
              }
            });
          } else if (statusStr.contains('error') ||
                   statusStr.contains('failed') ||
                   statusStr.contains('fatal') ||
                   statusStr.contains('exiting')) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('VPN Error: $status'),
                backgroundColor: Colors.red,
              ),
            );
            setState(() {
              loading = false;
              isAuthenticating = false;
              for (var client in clients) {
                client.connected = false;
              }
            });
          }
        });
      },
      onVpnStageChanged: (data, raw) {
        print('VPN Stage Changed: $data, Raw: $raw');
        setState(() {
          stage = data.toString();
        });
      },
    );
    openvpn.initialize();
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
    if (await Permission.notification.isDenied) {
      await Permission.notification.request();
    }
  }

  Future<void> fetchClients() async {
    setState(() => loading = true);
    try {
      final response = await http.get(Uri.parse('${backendUrl}/api/vpn_connect/clients/'));
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
      final response = await http.get(Uri.parse('${backendUrl}/api/vpn_connect/ovpn-content/${client.id}/'));
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
      if (Platform.isAndroid) {
        String config = await File(filePath).readAsString();
        setState(() {
          loading = true;
        });
        connectedClientId = client.id;
        
        try {
          await openvpn.connect(
            config,
            client.name,
            username: null,
            password: null,
            certIsRequired: true,
          );
        } catch (vpnError) {
          print('Error in OpenVPN.connect(): $vpnError');
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('VPN connection error: $vpnError'),
              backgroundColor: Colors.red,
            ),
          );
          setState(() {
            loading = false;
            client.connected = false;
          });
        }
      } else if (Platform.isWindows) {
        await _connectWindowsVPN(client, filePath);
      } else if (Platform.isLinux) {
        await _connectLinuxVPN(client, filePath);
      }
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

  Future<void> _connectWindowsVPN(VPNClient client, String filePath) async {
    setState(() {
      loading = true;
    });

    try {
      // Read the OVPN file content
      final config = await File(filePath).readAsString();
      print('OVPN Config content: $config'); // Debug log
      
      // Extract VPN configuration
      final serverAddress = _extractServerAddress(config);
      final serverPort = _extractServerPort(config);
      final protocol = _extractProtocol(config);
      
      print('Extracted VPN config - Server: $serverAddress, Port: $serverPort, Protocol: $protocol'); // Debug log
      
      if (serverAddress == null || serverPort == null) {
        throw Exception('Could not extract server information from OVPN file');
      }

      // First, check if the VPN connection already exists
      final checkResult = await Process.run('rasdial', []);
      print('Existing VPN connections: ${checkResult.stdout}'); // Debug log

      // Create VPN connection using rasdial
      print('Attempting to create VPN connection...'); // Debug log
      final result = await Process.run('rasdial', [
        client.name,
        serverAddress,
        '/phonebook:${client.name}.pbk',
        '/port:$serverPort'
      ]);

      print('rasdial result - Exit code: ${result.exitCode}'); // Debug log
      print('rasdial stdout: ${result.stdout}'); // Debug log
      print('rasdial stderr: ${result.stderr}'); // Debug log

      if (result.exitCode != 0) {
        // Try alternative connection method
        print('Trying alternative connection method...'); // Debug log
        final altResult = await Process.run('rasdial', [
          client.name,
          serverAddress
        ]);

        print('Alternative method result - Exit code: ${altResult.exitCode}'); // Debug log
        print('Alternative method stdout: ${altResult.stdout}'); // Debug log
        print('Alternative method stderr: ${altResult.stderr}'); // Debug log

        if (altResult.exitCode != 0) {
          throw Exception('Failed to create VPN connection: ${altResult.stderr}');
        }
      }

      // Verify connection
      await Future.delayed(const Duration(seconds: 5));
      final verifyResult = await Process.run('rasdial', []);
      print('Verification - Current connections: ${verifyResult.stdout}'); // Debug log

      if (verifyResult.stdout.toString().contains(client.name)) {
        setState(() {
          client.connected = true;
          connectedClientId = client.id;
        });
        
        // Save connection info
        await _prefs.setString('current_vpn', client.name);
        await _prefs.setString('vpn_config_path', filePath);
        
        // Update IP address
        await _getCurrentIpAddress();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Successfully connected to ${client.name}'),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        throw Exception('VPN connection verification failed');
      }
      
    } catch (e) {
      print('Error starting Windows VPN: $e'); // Debug log
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start VPN: $e'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Run as Admin',
            onPressed: () async {
              try {
                final result = await Process.run('powershell', [
                  '-Command',
                  'Start-Process -FilePath "${Platform.resolvedExecutable}" -Verb RunAs'
                ]);
                print('Restart as admin result: ${result.exitCode}'); // Debug log
                if (result.exitCode != 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to restart as administrator'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                print('Error restarting as admin: $e'); // Debug log
              }
            },
          ),
        ),
      );
      setState(() {
        client.connected = false;
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  Future<void> _connectLinuxVPN(VPNClient client, String filePath) async {
    setState(() {
      loading = true;
    });

    try {
      // Check if OpenVPN is installed
      final result = await Process.run('which', ['openvpn']);
      if (result.exitCode != 0) {
        throw Exception('OpenVPN is not installed. Please install it using your package manager.');
      }

      // Start OpenVPN process
      final process = await Process.start(
        'sudo',
        ['openvpn', '--config', filePath],
        mode: ProcessStartMode.detached,
      );

      // Wait for connection
      await Future.delayed(const Duration(seconds: 5));
      
      // Check if process is still running
      if (await process.exitCode == null) {
        setState(() {
          client.connected = true;
          connectedClientId = client.id;
        });
        
        // Save connection info
        await _prefs.setString('current_vpn', client.name);
        await _prefs.setString('vpn_config_path', filePath);
        
        // Update IP address
        await _getCurrentIpAddress();
      } else {
        throw Exception('VPN connection failed');
      }
    } catch (e) {
      print('Error starting Linux VPN: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to start VPN: $e'),
          backgroundColor: Colors.red,
        ),
      );
      setState(() {
        client.connected = false;
      });
    } finally {
      setState(() {
        loading = false;
      });
    }
  }

  String? _extractServerAddress(String config) {
    final remoteMatch = RegExp(r'remote\s+([^\s]+)').firstMatch(config);
    return remoteMatch?.group(1);
  }

  int? _extractServerPort(String config) {
    final remoteMatch = RegExp(r'remote\s+[^\s]+\s+(\d+)').firstMatch(config);
    return remoteMatch != null ? int.tryParse(remoteMatch.group(1)!) : null;
  }

  String? _extractProtocol(String config) {
    if (config.contains('proto udp')) return 'udp';
    if (config.contains('proto tcp')) return 'tcp';
    return null;
  }

  Future<void> disconnectVPN(VPNClient client) async {
    setState(() {
      loading = true;
    });
    try {
      if (Platform.isAndroid) {
        openvpn.disconnect();
      } else if (Platform.isWindows) {
        print('Attempting to disconnect VPN...'); // Debug log
        final result = await Process.run('rasdial', [
          client.name,
          '/disconnect'
        ]);
        
        print('Disconnect result - Exit code: ${result.exitCode}'); // Debug log
        print('Disconnect stdout: ${result.stdout}'); // Debug log
        print('Disconnect stderr: ${result.stderr}'); // Debug log
        
        if (result.exitCode != 0) {
          // Try alternative disconnect method
          print('Trying alternative disconnect method...'); // Debug log
          final altResult = await Process.run('rasdial', [
            client.name,
            '/disconnect',
            '/force'
          ]);
          
          print('Alternative disconnect result - Exit code: ${altResult.exitCode}'); // Debug log
          if (altResult.exitCode != 0) {
            throw Exception('Failed to disconnect VPN: ${altResult.stderr}');
          }
        }
      } else if (Platform.isLinux) {
        await Process.run('sudo', ['pkill', '-f', 'openvpn']);
      }
      
      setState(() {
        client.connected = false;
        connectedClientId = null;
      });
      
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
      print('Error disconnecting VPN: $e'); // Debug log
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to stop VPN: $e'),
          duration: const Duration(seconds: 10),
          action: SnackBarAction(
            label: 'Run as Admin',
            onPressed: () async {
              try {
                final result = await Process.run('powershell', [
                  '-Command',
                  'Start-Process -FilePath "${Platform.resolvedExecutable}" -Verb RunAs'
                ]);
                print('Restart as admin result: ${result.exitCode}'); // Debug log
                if (result.exitCode != 0) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Failed to restart as administrator'),
                      backgroundColor: Colors.red,
                    ),
                  );
                }
              } catch (e) {
                print('Error restarting as admin: $e'); // Debug log
              }
            },
          ),
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
        title: const Text('VPN Clients'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: fetchClients,
          ),
        ],
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
    // Clean up any temporary credential files
    if (Platform.isAndroid) {
      Directory(Directory.systemTemp.path)
          .listSync()
          .where((file) => file.path.endsWith('_credentials'))
          .forEach((file) {
        try {
          file.deleteSync();
        } catch (e) {
          print('Error cleaning up credential file: $e');
        }
      });
    }
    super.dispose();
  }
}