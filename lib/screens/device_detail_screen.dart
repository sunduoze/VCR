import 'package:flutter/material.dart';
import '../app/theme.dart';
import '../src/rust/api/device_api.dart';
import '../src/rust/core/device/models.dart';
import '../widgets/status_indicator.dart';

class DeviceDetailScreen extends StatefulWidget {
  final String deviceId;
  const DeviceDetailScreen({super.key, required this.deviceId});

  @override
  State<DeviceDetailScreen> createState() => _DeviceDetailScreenState();
}

class _DeviceDetailScreenState extends State<DeviceDetailScreen> {
  DeviceInfo? _device;
  bool _isLoading = true;
  String? _error;
  
  // 配置参数
  final _configFormKey = GlobalKey<FormState>();
  int _sampleRate = 1000;
  int _dataPoints = 100;
  bool _autoReconnect = true;
  int _timeoutMs = 5000;

  @override
  void initState() {
    super.initState();
    _loadDevice();
  }

  Future<void> _loadDevice() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    
    try {
      final device = getDevice(deviceId: widget.deviceId);
      setState(() {
        _device = device;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<void> _connect() async {
    if (_device == null) return;
    try {
      await connectDevice(deviceId: _device!.id);
      await _loadDevice();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备连接成功'), backgroundColor: AppTheme.success),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('连接失败: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _disconnect() async {
    if (_device == null) return;
    try {
      await disconnectDevice(deviceId: _device!.id);
      await _loadDevice();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('设备已断开'), backgroundColor: AppTheme.warning),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('断开失败: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  Future<void> _removeDevice() async {
    if (_device == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除设备 "${_device!.name}" 吗？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      try {
        await removeDevice(deviceId: _device!.id);
        if (mounted) Navigator.pop(context, true);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('删除失败: $e'), backgroundColor: AppTheme.error),
          );
        }
      }
    }
  }

  void _saveConfig() {
    if (_configFormKey.currentState!.validate()) {
      _configFormKey.currentState!.save();
      // TODO: 调用 Rust API 保存配置
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存'), backgroundColor: AppTheme.success),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: Text(_device?.name ?? '设备详情'),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: _loadDevice, tooltip: '刷新'),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'delete') _removeDevice();
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'delete', child: Text('删除设备', style: TextStyle(color: AppTheme.error))),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text('加载失败: $_error', style: const TextStyle(color: AppTheme.error)))
              : _buildContent(),
    );
  }

  Widget _buildContent() {
    if (_device == null) return const Center(child: Text('设备不存在'));
    
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 状态卡片
          _buildStatusCard(),
          const SizedBox(height: 16),
          
          // 连接信息
          _buildConnectionInfo(),
          const SizedBox(height: 16),
          
          // 操作按钮
          _buildActionButtons(),
          const SizedBox(height: 24),
          
          // 配置参数
          _buildConfigSection(),
          const SizedBox(height: 24),
          
          // 数据预览
          _buildDataPreview(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    final status = _device!.status;
    Color statusColor;
    String statusText;
    IconData statusIcon;
    
    switch (status) {
      case DeviceStatus.connected:
        statusColor = AppTheme.success;
        statusText = '已连接';
        statusIcon = Icons.check_circle;
        break;
      case DeviceStatus.connecting:
        statusColor = AppTheme.warning;
        statusText = '连接中...';
        statusIcon = Icons.pending;
        break;
      case DeviceStatus.error:
        statusColor = AppTheme.error;
        statusText = '错误';
        statusIcon = Icons.error;
        break;
      case DeviceStatus.disconnected:
        statusColor = AppTheme.textSecondary;
        statusText = '未连接';
        statusIcon = Icons.circle_outlined;
        break;
    }
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(statusIcon, size: 48, color: statusColor),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_device!.name, style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      StatusIndicator(status: status, size: 10),
                      const SizedBox(width: 8),
                      Text(statusText, style: TextStyle(color: statusColor, fontWeight: FontWeight.w500)),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('类型: ${_device!.deviceType}', style: const TextStyle(color: AppTheme.textSecondary)),
                Text('ID: ${_device!.id.substring(0, 8)}...', style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionInfo() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('连接信息', style: Theme.of(context).textTheme.titleLarge),
            const Divider(color: AppTheme.border),
            _buildInfoRow('连接类型', _device!.connectionType.name.toUpperCase()),
            _buildInfoRow('地址', _device!.address),
            if (_device!.lastSeen != null)
              _buildInfoRow('最后通信', _device!.lastSeen!),
            if (_device!.errorMessage != null)
              _buildInfoRow('错误信息', _device!.errorMessage!, valueColor: AppTheme.error),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, {Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 100, child: Text(label, style: const TextStyle(color: AppTheme.textSecondary))),
          Expanded(child: Text(value, style: TextStyle(color: valueColor ?? AppTheme.textPrimary))),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final isConnected = _device!.status == DeviceStatus.connected;
    
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: ElevatedButton.icon(
                onPressed: isConnected ? _disconnect : _connect,
                icon: Icon(isConnected ? Icons.link_off : Icons.link),
                label: Text(isConnected ? '断开连接' : '连接'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: isConnected ? AppTheme.warning : AppTheme.primaryDim,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _removeDevice,
                icon: const Icon(Icons.delete_outline),
                label: const Text('删除设备'),
                style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: () {
              Navigator.pushNamed(context, '/debug', arguments: _device!.id);
            },
            icon: const Icon(Icons.terminal),
            label: const Text('调试控制台'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.secondary,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildConfigSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('配置参数', style: Theme.of(context).textTheme.titleLarge),
                TextButton.icon(
                  onPressed: _saveConfig,
                  icon: const Icon(Icons.save, size: 18),
                  label: const Text('保存'),
                ),
              ],
            ),
            const Divider(color: AppTheme.border),
            Form(
              key: _configFormKey,
              child: Column(
                children: [
                  _buildConfigField(
                    '采样率 (Hz)',
                    _sampleRate.toString(),
                    (value) => _sampleRate = int.tryParse(value ?? '') ?? 1000,
                    keyboardType: TextInputType.number,
                  ),
                  _buildConfigField(
                    '数据点数',
                    _dataPoints.toString(),
                    (value) => _dataPoints = int.tryParse(value ?? '') ?? 100,
                    keyboardType: TextInputType.number,
                  ),
                  SwitchListTile(
                    title: const Text('自动重连'),
                    subtitle: const Text('连接断开时自动尝试重连'),
                    value: _autoReconnect,
                    onChanged: (value) => setState(() => _autoReconnect = value),
                    activeThumbColor: AppTheme.primary,
                  ),
                  _buildConfigField(
                    '超时时间 (ms)',
                    _timeoutMs.toString(),
                    (value) => _timeoutMs = int.tryParse(value ?? '') ?? 5000,
                    keyboardType: TextInputType.number,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConfigField(
    String label,
    String initialValue,
    FormFieldSetter<String> onSaved, {
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextFormField(
        initialValue: initialValue,
        decoration: InputDecoration(
          labelText: label,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
        ),
        keyboardType: keyboardType,
        onSaved: onSaved,
        validator: (value) {
          if (value == null || value.isEmpty) return '不能为空';
          if (keyboardType == TextInputType.number && int.tryParse(value) == null) {
            return '请输入有效数字';
          }
          return null;
        },
      ),
    );
  }

  Widget _buildDataPreview() {
    final isConnected = _device!.status == DeviceStatus.connected;
    
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('数据预览', style: Theme.of(context).textTheme.titleLarge),
                if (isConnected)
                  TextButton.icon(
                    onPressed: () {
                      // TODO: 导航到数据监控页
                    },
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: const Text('监控'),
                  ),
              ],
            ),
            const Divider(color: AppTheme.border),
            if (!isConnected)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('连接设备后可查看实时数据', style: TextStyle(color: AppTheme.textSecondary)),
                ),
              )
            else
              SizedBox(
                height: 150,
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.show_chart, size: 48, color: AppTheme.textSecondary),
                      const SizedBox(height: 8),
                      const Text('数据图表区域', style: TextStyle(color: AppTheme.textSecondary)),
                      TextButton(
                        onPressed: () {
                          // TODO: 导航到数据监控页
                        },
                        child: const Text('查看完整监控'),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
