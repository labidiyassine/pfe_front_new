# VPN Client Application

This application allows you to connect to VPN servers using OpenVPN configuration files.

## Running on Windows

### Important: Administrator Privileges Required

For the VPN connection to work properly on Windows, the application needs to run with administrator privileges. This is because OpenVPN needs to:

1. Create a virtual network adapter
2. Modify system routes
3. Change network settings

### How to Run as Administrator

#### Method 1: Run the Built Application as Administrator

After building the application:

1. Navigate to the build folder: `build\windows\x64\runner\Debug\` or `build\windows\x64\runner\Release\`
2. Right-click on `pfe_front_new.exe`
3. Select "Run as administrator"
4. Allow the application to make changes to your device when prompted

#### Method 2: Run from Visual Studio with Admin Rights

1. Open Visual Studio as administrator
2. Open the project
3. Build and run the application

#### Method 3: During Development

When running from Flutter:

1. Open Command Prompt as administrator
2. Navigate to your project directory
3. Run `flutter run -d windows`

### Troubleshooting

If you see messages like "Access denied" or "Accès refusé" when connecting to a VPN, it means the application does not have sufficient permissions to modify network routes. This is normal - just restart the application with admin rights as described above.

## Features

- Connect to VPN servers using OpenVPN configurations
- Save and manage multiple VPN configurations
- Automatic IP address update
- Real-time connection status

## Requirements

- Flutter 3.2.0 or higher
- Windows 10 or higher (for Windows)
- OpenVPN TAP adapter (automatically installed)
