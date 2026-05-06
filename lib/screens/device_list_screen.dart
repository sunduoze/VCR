import 'dart:async';
import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../app/routes.dart';
import '../widgets/main_shell.dart' show VcrLogo;
import '../widgets/status_indicator.dart';
import '../screens/settings_screen.dart' show AppConfig;
import '../src/rust/api/device_api.dart';
import '../src/rust/core/device/models.dart';

// ── Top-level helpers for serial config parsing ──

DataBits _parseDataBits(String s) {
  switch (s) {
    case '5': return DataBits.five;
    case '6': return DataBits.six;
    case '7': return DataBits.seven;
    default: return DataBits.eight;
  }
}

StopBits _parseStopBits(String s) {
  switch (s) {
    case '2': return StopBits.two;
    default: return StopBits.one;
  }
}

Parity _parseParity(String s) {
  switch (s.toUpperCase()) {
    case 'O': return Parity.odd;
    case 'E': return Parity.even;
    default: return Parity.none;
  }
}

FlowControl _parseFlowControl(String s) {
  switch (s.toUpperCase()) {
    case 'H': return FlowControl.hardware;
    case 'S': return FlowControl.software;
    default: return FlowControl.none;
  }
}

class DeviceListScreen extends StatefulWidget {
  const DeviceListScreen({super.key});

  @override
  State<DeviceListScreen> createState() => _DeviceListScreenState();
}

class _DeviceListScreenState extends State<DeviceListScreen> {
  List<DeviceInfo> _devices = [];
  List<String> _protocols = []; // protocol labels from getSupportedProtocols()
  List<String> _deviceSortOrder = []; // persisted sort order

  @override
  void initState() {
    super.initState();
    _loadSortOrder();
    _loadDevices();
    _loadProtocols();
    // Don't auto-scan ports �?user must click refresh in dialog
    // Scanning happens on-demand when opening add/edit device dialog
  }

  Future<void> _loadSortOrder() async {
    final config = await AppConfig.load();
    final order = config['deviceSortOrder'] as List?;
    if (order != null) {
      _deviceSortOrder = order.cast<String>();
    }
  }

  Future<void> _loadDevices() async {
    final devices = listDevices();
    // Sort: connected first, then by persisted sort order (previously connected), then alphabetical
    _sortDevices(devices);
    setState(() => _devices = devices);
  }

  /// Sort devices: connected first, then previously connected (by sort order), then alphabetically
  void _sortDevices(List<DeviceInfo> devices) {
    devices.sort((a, b) {
      // Connected devices always first
      final aConn = a.status == DeviceStatus.connected ? 0 : 1;
      final bConn = b.status == DeviceStatus.connected ? 0 : 1;
      if (aConn != bConn) return aConn - bConn;

      // Then by persisted sort order (previously connected devices higher)
      final aIdx = _deviceSortOrder.indexOf(a.id);
      final bIdx = _deviceSortOrder.indexOf(b.id);
      final aInOrder = aIdx >= 0 ? aIdx : 999999;
      final bInOrder = bIdx >= 0 ? bIdx : 999999;
      if (aInOrder != bInOrder) return aInOrder - bInOrder;

      // Finally alphabetical
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  /// Save current device order + connected device IDs to app config
  Future<void> _saveDeviceState() async {
    // Save sort order (all device IDs in current display order)
    final order = _devices.map((d) => d.id).toList();
    await AppConfig.saveDeviceSortOrder(order);

    // Save connected device IDs for auto-reconnect
    final connectedIds = _devices
        .where((d) => d.status == DeviceStatus.connected)
        .map((d) => d.id)
        .toList();
    await AppConfig.saveLastConnectedDevices(connectedIds);
  }

  Future<void> _loadProtocols() async {
    // getSupportedProtocols returns List<String> (protocol labels)
    final protocols = getSupportedProtocols();
    setState(() => _protocols = protocols);
  }

  /// Scan serial ports (sync, ~50ms with cache)
  List<PortInfo> _scanPortsSync() {
    try {
      return scanSerialPorts();
    } catch (e) {
      debugPrint('Scan ports error: $e');
      return [];
    }
  }

  void _showAddDeviceDialog() {
    showDialog(
      context: context,
      builder: (context) => _DeviceDialog(
        availablePorts: _scanPortsSync(),
        protocols: _protocols,
        onConfirm: (name, connType, address, protocol) async {
          if (connType == ConnectionType.serial) {
            final parts = address.split(':');
            final port = parts[0];
            final baudRate = parts.length > 1 ? int.tryParse(parts[1]) ?? 9600 : 9600;
            final dataBits = parts.length > 2 ? _parseDataBits(parts[2]) : DataBits.eight;
            final stopBits = parts.length > 3 ? _parseStopBits(parts[3]) : StopBits.one;
            final parity = parts.length > 4 ? _parseParity(parts[4]) : Parity.none;
            final flowControl = parts.length > 5 ? _parseFlowControl(parts[5]) : FlowControl.none;
            // 解析硬件流控制设置
            final dtrEnabled = parts.length > 7 && parts[7] == '1';
            final rtsEnabled = parts.length > 8 && parts[8] == '1';
            final breakEnabled = parts.length > 9 && parts[9] == '1';
            addSerialDevice(
              name: name,
              port: port,
              baudRate: baudRate,
              protocol: protocol,
              dataBits: dataBits,
              stopBits: stopBits,
              parity: parity,
              flowControl: flowControl,
              receiveTimeoutMs: BigInt.from(100),
              dtrEnabled: dtrEnabled,
              rtsEnabled: rtsEnabled,
              breakEnabled: breakEnabled,
            );
            saveDevices(); // 持久化新设备
          } else if (connType == ConnectionType.tcp) {
            final parts = address.split(':');
            final host = parts[0];
            final port = parts.length > 1 ? int.tryParse(parts[1]) ?? 502 : 502;
            addTcpDevice(name: name, host: host, port: port, protocol: protocol);
            saveDevices(); // 持久化新设备
          }
          await _loadDevices();
        },
      ),
    );
  }

  void _showEditDeviceDialog(DeviceInfo device) {
    showDialog(
      context: context,
      builder: (context) => _DeviceDialog(
        availablePorts: _scanPortsSync(),
        protocols: _protocols,
        editDevice: device,
        onConfirm: (name, connType, address, protocol) async {
          await updateDevice(deviceId: device.id, name: name, address: address, protocol: protocol);
          saveDevices(); // 持久化更�?          await _loadDevices();
        },
      ),
    );
  }

  Future<void> _toggleConnect(DeviceInfo device) async {
    if (device.status == DeviceStatus.connected) {
      await disconnectDevice(deviceId: device.id);
    } else {
      await connectDevice(deviceId: device.id);
    }
    await _loadDevices();
    _saveDeviceState();
  }

  Future<void> _navigateToDetail(DeviceInfo device) async {
    final result = await Navigator.pushNamed(
      context,
      AppRoutes.deviceDetail,
      arguments: device.id,
    );
    if (result == true) {
      await _loadDevices();
    }
  }

  Future<void> _removeDevice(String deviceId) async {
    await removeDevice(deviceId: deviceId);
    saveDevices(); // 持久化删�?    await _loadDevices();
    _saveDeviceState();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Device Management'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _showAddDeviceDialog,
            tooltip: 'Add Device',
          ),
        ],
      ),
      body: _devices.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const VcrLogo(size: 64),
                  const SizedBox(height: 16),
                  Text('No devices configured', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  Text('Click + to add a device', style: Theme.of(context).textTheme.bodyMedium),
                ],
              ),
            )
          : RefreshIndicator(
              onRefresh: _loadDevices,
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _devices.length,
                itemBuilder: (context, index) => _DeviceCard(
                  device: _devices[index],
                  onEdit: () => _showEditDeviceDialog(_devices[index]),
                  onRemove: () => _removeDevice(_devices[index].id),
                  onTap: () => _navigateToDetail(_devices[index]),
                ),
              ),
            ),
    );
  }
}

class _DeviceCard extends StatelessWidget {
  final DeviceInfo device;
  final VoidCallback onEdit;
  final VoidCallback onRemove;
  final VoidCallback onTap;

  const _DeviceCard({
    required this.device,
    required this.onEdit,
    required this.onRemove,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 第一行：状态点 + 名称 + 虚拟徽章 + 箭头
              Row(
                children: [
                  StatusIndicator(status: device.status),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      device.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (device.isVirtual) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.purple.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.purple.withOpacity(0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: const [
                          Icon(Icons.memory, size: 14, color: Colors.purple),
                          SizedBox(width: 4),
                          Text(
                            'VIRTUAL',
                            style: TextStyle(
                              color: Colors.purple,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Icon(Icons.chevron_right, size: 20, color: AppTheme.textSecondary.withOpacity(0.5)),
                ],
              ),
              const SizedBox(height: 12),
              // 第二行：连接信息醒目展示
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight.withOpacity(0.5),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: AppTheme.primary.withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    Icon(
                      _connTypeIcon(device.connectionType),
                      size: 18,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            device.address,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: AppTheme.primary,
                            ),
                          ),
                          if (device.serverInfo != null && device.serverInfo!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                device.serverInfo!,
                                style: TextStyle(
                                  fontSize: 11,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    _TypeChip(label: _connTypeLabel(device.connectionType)),
                    const SizedBox(width: 6),
                    _ProtocolChip(label: _protocolLabel(device.protocol)),
                  ],
                ),
              ),
              // 错误信息
              if (device.errorMessage != null) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, size: 16, color: AppTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          device.errorMessage!,
                          style: TextStyle(color: AppTheme.error, fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              // 操作按钮行（仅编辑和删除，无连接按钮�?              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: onEdit,
                    tooltip: 'Edit',
                    color: AppTheme.primary,
                    iconSize: 20,
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: onRemove,
                    tooltip: 'Remove',
                    color: AppTheme.error,
                    iconSize: 20,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  IconData _connTypeIcon(ConnectionType t) {
    switch (t) {
      case ConnectionType.serial:
        return Icons.usb;
      case ConnectionType.tcp:
        return Icons.lan;
      case ConnectionType.usb:
        return Icons.usb;
      case ConnectionType.ble:
        return Icons.bluetooth;
      case ConnectionType.wifi:
        return Icons.wifi;
    }
  }

  String _connTypeLabel(ConnectionType t) {
    switch (t) {
      case ConnectionType.serial:
        return 'Serial';
      case ConnectionType.tcp:
        return 'TCP';
      case ConnectionType.usb:
        return 'USB';
      case ConnectionType.ble:
        return 'BLE';
      case ConnectionType.wifi:
        return 'WiFi';
    }
  }

  String _protocolLabel(Protocol p) {
    switch (p) {
      case Protocol.raw:
        return 'Raw';
      case Protocol.modbusRtu:
        return 'Modbus RTU';
      case Protocol.modbusTcp:
        return 'Modbus TCP';
      case Protocol.scpi:
        return 'SCPI';
      case Protocol.csv:
        return 'CSV';
      case Protocol.private:
        return 'Private';
    }
  }
}

class _TypeChip extends StatelessWidget {
  final String label;
  const _TypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.primary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.primary.withOpacity(0.3)),
      ),
      child: Text(label, style: const TextStyle(color: AppTheme.primary, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

class _ProtocolChip extends StatelessWidget {
  final String label;
  const _ProtocolChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.secondary.withOpacity(0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppTheme.secondary.withOpacity(0.3)),
      ),
      child: Text(label, style: const TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

/// 统一的设备对话框（支持新增和编辑）
class _DeviceDialog extends StatefulWidget {
  final List<PortInfo> availablePorts;
  final List<String> protocols; // protocol labels
  final DeviceInfo? editDevice; // null = 新增, 非null = 编辑
  final void Function(String name, ConnectionType connType, String address, Protocol protocol) onConfirm;

  const _DeviceDialog({
    required this.availablePorts,
    required this.protocols,
    this.editDevice,
    required this.onConfirm,
  });

  @override
  State<_DeviceDialog> createState() => _DeviceDialogState();
}

class _DeviceDialogState extends State<_DeviceDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _hostController;
  late final TextEditingController _portController;
  final _customBaudRateController = TextEditingController();
  
  late ConnectionType _connType;
  late Protocol _protocol;
  String? _selectedPort;
  late int _selectedBaudRate;
  bool _customBaudRate = false;
  late DataBits _selectedDataBits;
  late StopBits _selectedStopBits;
  late Parity _selectedParity;
  late FlowControl _selectedFlowControl;
  late bool _dtrEnabled;
  late bool _rtsEnabled;
  late bool _breakEnabled;

  // 对话框自己管理端口列表和扫描状态
  List<PortInfo> _ports = [];
  bool _scanning = false;

  final List<int> _baudRateOptions = [9600, 38400, 115200, 500000, 1000000, 5000000];
  bool get _isEditing => widget.editDevice != null;

  late String _selectedProtocolLabel; // selected protocol label (for UI dropdown)

  @override
  void initState() {
    super.initState();
    _ports = List.from(widget.availablePorts);
    _selectedProtocolLabel = widget.protocols.isNotEmpty ? widget.protocols.first : 'SCPI';
    
    if (widget.editDevice != null) {
      // 编辑模式：从现有设备填充
      final d = widget.editDevice!;
      _nameController = TextEditingController(text: d.name);
      _connType = d.connectionType;
      _protocol = d.protocol;
      _selectedDataBits = DataBits.eight;
      _selectedStopBits = StopBits.one;
      _selectedParity = Parity.none;
      _selectedFlowControl = FlowControl.none;
      
      final parts = d.address.split(':');
      if (_connType == ConnectionType.serial) {
        _selectedPort = parts.isNotEmpty ? parts[0] : null;
        _selectedBaudRate = parts.length > 1 ? int.tryParse(parts[1]) ?? 115200 : 115200;
        if (parts.length > 2) _selectedDataBits = _parseDataBits(parts[2]);
        if (parts.length > 3) _selectedStopBits = _parseStopBits(parts[3]);
        if (parts.length > 4) _selectedParity = _parseParity(parts[4]);
        if (parts.length > 5) _selectedFlowControl = _parseFlowControl(parts[5]);
        // 解析硬件流控制设置 (dtr:rts:bk)
        _dtrEnabled = parts.length > 7 && parts[7] == '1';
        _rtsEnabled = parts.length > 8 && parts[8] == '1';
        _breakEnabled = parts.length > 9 && parts[9] == '1';
        if (!_baudRateOptions.contains(_selectedBaudRate)) {
          _customBaudRate = true;
          _customBaudRateController.text = _selectedBaudRate.toString();
          _selectedBaudRate = 115200;
        }
      } else {
        _hostController = TextEditingController(text: parts.isNotEmpty ? parts[0] : '192.168.1.1');
        _portController = TextEditingController(text: parts.length > 1 ? parts[1] : '502');
      }
    } else {
      // 新增模式：默认值为空
      _nameController = TextEditingController();
      _connType = ConnectionType.serial;
      _hostController = TextEditingController(text: '192.168.1.1');
      _portController = TextEditingController(text: '502');
      _selectedBaudRate = 115200;
      _selectedDataBits = DataBits.eight;
      _selectedStopBits = StopBits.one;
      _selectedParity = Parity.none;
      _selectedFlowControl = FlowControl.none;
      _dtrEnabled = false;
      _rtsEnabled = false;
      _breakEnabled = false;
      _protocol = Protocol.scpi; // 默认 SCPI 协议
    }
  }

  String get _currentAddress {
    if (_connType == ConnectionType.serial) {
      if (_selectedPort == null) return '';
      final baud = _customBaudRate && _customBaudRateController.text.isNotEmpty
          ? _customBaudRateController.text
          : _selectedBaudRate.toString();
      final db = _selectedDataBits == DataBits.eight ? '8'
          : _selectedDataBits == DataBits.seven ? '7'
          : _selectedDataBits == DataBits.six ? '6' : '5';
      final sb = _selectedStopBits == StopBits.two ? '2' : '1';
      final pr = _selectedParity == Parity.odd ? 'O'
          : _selectedParity == Parity.even ? 'E' : 'N';
      final fc = _selectedFlowControl == FlowControl.hardware ? 'H'
          : _selectedFlowControl == FlowControl.software ? 'S' : 'N';
      return '$_selectedPort:$baud:$db:$sb:$pr:$fc:100:${_dtrEnabled ? '1' : '0'}:${_rtsEnabled ? '1' : '0'}:${_breakEnabled ? '1' : '0'}';
    } else {
      return '${_hostController.text}:${_portController.text}';
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _hostController.dispose();
    _portController.dispose();
    _customBaudRateController.dispose();
    super.dispose();
  }

  /// 扫描串口（对话框自己管理，不依赖父组件）
  void _scanPorts() {
    if (_scanning) return;
    setState(() => _scanning = true);
    try {
      final ports = scanSerialPorts();
      if (mounted) setState(() => _ports = ports);
    } catch (e) {
      debugPrint('Scan ports error: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      title: Row(
        children: [
          Text(_isEditing ? 'Edit Device' : 'Add Device'),
          const Spacer(),
          if (_connType == ConnectionType.serial)
            IconButton(
              icon: _scanning
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.refresh),
              onPressed: _scanning ? null : _scanPorts,
              tooltip: 'Refresh Ports',
            ),
        ],
      ),
      content: SingleChildScrollView(
        child: SizedBox(
          width: 480,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 设备名称
              TextField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Device Name *',
                  hintText: 'e.g., Oscilloscope #1',
                ),
              ),
              const SizedBox(height: 16),
              
              // 连接类型（编辑模式下不可更改）
              DropdownButtonFormField<ConnectionType>(
                value: _connType,
                decoration: const InputDecoration(labelText: 'Connection Type'),
                items: const [
                  DropdownMenuItem(value: ConnectionType.serial, child: Text('Serial / COM')),
                  DropdownMenuItem(value: ConnectionType.tcp, child: Text('TCP/IP')),
                ],
                onChanged: _isEditing ? null : (v) => setState(() => _connType = v!),
              ),
              const SizedBox(height: 16),
              
              // 协议选择
              DropdownButtonFormField<String>(
                value: _selectedProtocolLabel,
                decoration: const InputDecoration(
                  labelText: 'Protocol',
                  helperText: 'Select communication protocol',
                ),
                items: widget.protocols.map((label) => DropdownMenuItem<String>(
                  value: label,
                  child: Text(label),
                )).toList(),
                onChanged: (v) => setState(() {
                  _selectedProtocolLabel = v!;
                  _protocol = Protocol.values.firstWhere(
                    (p) => p.name.toLowerCase() == v.toLowerCase() || p.name == v,
                    orElse: () => Protocol.scpi,
                  );
                }),
              ),
              const SizedBox(height: 16),
              
              // 串口配置
              if (_connType == ConnectionType.serial) ...[
                DropdownButtonFormField<String>(
                  value: _selectedPort,
                  decoration: InputDecoration(
                    labelText: 'Serial Port',
                    suffixIcon: _ports.isEmpty 
                        ? const Icon(Icons.warning, color: AppTheme.warning)
                        : null,
                  ),
                  hint: Text(
                    _ports.isEmpty 
                        ? 'No ports found - click refresh' 
                        : 'Select a port',
                  ),
                  items: _ports.map((p) => DropdownMenuItem(
                    value: p.name,
                    child: Row(
                      children: [
                        Icon(
                          p.isVirtual ? Icons.memory : Icons.usb,
                          size: 16,
                          color: p.isVirtual ? Colors.purple : AppTheme.textSecondary,
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            p.isVirtual
                                ? p.name
                                : '${p.name} (${p.description})',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (p.isVirtual) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: Colors.purple.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              'VIRTUAL',
                              style: TextStyle(fontSize: 9, color: Colors.purple, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ],
                    ),
                  )).toList(),
                  onChanged: (v) {
                    setState(() => _selectedPort = v);
                  },
                ),
                const SizedBox(height: 16),
                
                // Baud rate
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        value: _customBaudRate ? null : _selectedBaudRate,
                        decoration: const InputDecoration(labelText: 'Baud Rate'),
                        items: _baudRateOptions.map((br) => DropdownMenuItem(
                          value: br,
                          child: Text(br >= 1000000 ? '${br ~/ 1000000}M' : br.toString()),
                        )).toList(),
                        onChanged: _customBaudRate 
                            ? null 
                            : (v) => setState(() => _selectedBaudRate = v!),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Custom', style: TextStyle(fontSize: 11)),
                        Switch(
                          value: _customBaudRate,
                          onChanged: (v) => setState(() => _customBaudRate = v),
                        ),
                      ],
                    ),
                  ],
                ),
                if (_customBaudRate) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _customBaudRateController,
                    decoration: const InputDecoration(
                      labelText: 'Custom Baud Rate',
                      hintText: 'e.g., 500000',
                    ),
                    keyboardType: TextInputType.number,
                  ),
                ],
                const SizedBox(height: 16),

                // Data Bits, Stop Bits, Parity, Flow Control �?2x2 grid
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<DataBits>(
                        value: _selectedDataBits,
                        decoration: const InputDecoration(
                          labelText: 'Data Bits',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: DataBits.eight, child: Text('8')),
                          DropdownMenuItem(value: DataBits.seven, child: Text('7')),
                          DropdownMenuItem(value: DataBits.six, child: Text('6')),
                          DropdownMenuItem(value: DataBits.five, child: Text('5')),
                        ],
                        onChanged: (v) => setState(() => _selectedDataBits = v!),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<StopBits>(
                        value: _selectedStopBits,
                        decoration: const InputDecoration(
                          labelText: 'Stop Bits',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: StopBits.one, child: Text('1')),
                          DropdownMenuItem(value: StopBits.two, child: Text('2')),
                        ],
                        onChanged: (v) => setState(() => _selectedStopBits = v!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<Parity>(
                        value: _selectedParity,
                        decoration: const InputDecoration(
                          labelText: 'Parity',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: Parity.none, child: Text('None')),
                          DropdownMenuItem(value: Parity.odd, child: Text('Odd')),
                          DropdownMenuItem(value: Parity.even, child: Text('Even')),
                        ],
                        onChanged: (v) => setState(() => _selectedParity = v!),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: DropdownButtonFormField<FlowControl>(
                        value: _selectedFlowControl,
                        decoration: const InputDecoration(
                          labelText: 'Flow Control',
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        ),
                        items: const [
                          DropdownMenuItem(value: FlowControl.none, child: Text('None')),
                          DropdownMenuItem(value: FlowControl.hardware, child: Text('Hardware (RTS/CTS)')),
                          DropdownMenuItem(value: FlowControl.software, child: Text('Software (XON/XOFF)')),
                        ],
                        onChanged: (v) => setState(() => _selectedFlowControl = v!),
                      ),
                    ),
                  ],
                ),
              ],
              
              // 硬件流控制信号配置 (DTR/RTS/Break)
              if (_connType == ConnectionType.serial) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: CheckboxListTile(
                        title: const Text('DTR', style: TextStyle(fontSize: 13)),
                        subtitle: const Text('Data Terminal Ready', style: TextStyle(fontSize: 10)),
                        value: _dtrEnabled,
                        onChanged: (v) => setState(() => _dtrEnabled = v ?? false),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    Expanded(
                      child: CheckboxListTile(
                        title: const Text('RTS', style: TextStyle(fontSize: 13)),
                        subtitle: const Text('Request To Send', style: TextStyle(fontSize: 10)),
                        value: _rtsEnabled,
                        onChanged: (v) => setState(() => _rtsEnabled = v ?? false),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                    Expanded(
                      child: CheckboxListTile(
                        title: const Text('BREAK', style: TextStyle(fontSize: 13)),
                        subtitle: const Text('Break Signal', style: TextStyle(fontSize: 10)),
                        value: _breakEnabled,
                        onChanged: (v) => setState(() => _breakEnabled = v ?? false),
                        dense: true,
                        controlAffinity: ListTileControlAffinity.leading,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ],
                ),
              ],
              
              // TCP 配置
              if (_connType == ConnectionType.tcp) ...[
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _hostController,
                        decoration: const InputDecoration(
                          labelText: 'Host / IP',
                          hintText: 'e.g., 192.168.1.100',
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 1,
                      child: TextField(
                        controller: _portController,
                        decoration: const InputDecoration(
                          labelText: 'Port',
                          hintText: '502',
                        ),
                        keyboardType: TextInputType.number,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final name = _nameController.text.trim();
            if (name.isEmpty) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please enter device name')),
              );
              return;
            }
            
            if (_connType == ConnectionType.serial && _selectedPort == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Please select a serial port')),
              );
              return;
            }
            
            widget.onConfirm(name, _connType, _currentAddress, _protocol);
            Navigator.pop(context);
          },
          child: Text(_isEditing ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}
