import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

void main() => runApp(const UVMonitorApp());

class UVMonitorApp extends StatelessWidget {
  const UVMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32-C3 UV Monitor',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
      ),
      home: const UVMonitorScreen(),
    );
  }
}

class UVRecord {
  final DateTime timestamp;
  final double mvMw;
  final double uvIndex;
  final int rssi;

  UVRecord({
    required this.timestamp,
    required this.mvMw,
    required this.uvIndex,
    required this.rssi,
  });
}

class UVMonitorScreen extends StatefulWidget {
  const UVMonitorScreen({super.key});

  @override
  State<UVMonitorScreen> createState() => _UVMonitorScreenState();
}

class _UVMonitorScreenState extends State<UVMonitorScreen> {
  static const String mqttBroker = 'broker.hivemq.com';
  static const int wsPort = 8884;
  static const String mqttTopic = 'venkat_iot/sensors/uv/node_01';

  MqttServerClient? _client;
  String _status = 'Connecting via Secure WebSockets...';
  bool _isConnected = false;
  bool _isSimulating = false;
  Timer? _simTimer;

  double _latestMv = 0.0;
  double _latestUv = 0.0;
  int _latestRssi = 0;
  int _packetCount = 0;
  final List<UVRecord> _records = [];

  @override
  void initState() {
    super.initState();
    _connectMqttWebSocket();
  }

  @override
  void dispose() {
    _simTimer?.cancel();
    _client?.disconnect();
    super.dispose();
  }

  Future<void> _connectMqttWebSocket() async {
    final clientId = 'android_uv_${Random().nextInt(999999)}';

    _client?.disconnect();
    _client = MqttServerClient.withPort(mqttBroker, clientId, wsPort);
    _client!.useWebSocket = true;
    _client!.secure = true;
    _client!.keepAlivePeriod = 20;
    _client!.autoReconnect = true;
    _client!.websocketProtocols = MqttClientConstants.protocolsSingleDefault;

    _client!.onDisconnected = () {
      if (mounted && !_isSimulating) {
        setState(() {
          _isConnected = false;
          _status = 'Disconnected — Tap Refresh';
        });
      }
    };

    _client!.connectionMessage = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .startClean()
        .withWillQos(MqttQos.atLeastOnce);

    try {
      setState(() => _status = 'Connecting to WSS Port 8884...');
      await _client!.connect();
    } catch (e) {
      _client!.disconnect();
      if (mounted) {
        setState(() {
          _isConnected = false;
          _status = 'Connection Error: Check Network';
        });
      }
      return;
    }

    if (_client!.connectionStatus?.state == MqttConnectionState.connected) {
      if (mounted) {
        setState(() {
          _isConnected = true;
          _status = 'Connected! Listening for ESP32...';
        });
      }

      _client!.subscribe(mqttTopic, MqttQos.atLeastOnce);

      _client!.updates!
          .listen((List<MqttReceivedMessage<MqttMessage?>> events) {
        final recMess = events[0].payload as MqttPublishMessage;
        final rawJson =
            MqttPublishPayload.bytesToStringAsString(recMess.payload.message);

        try {
          final Map<String, dynamic> data = jsonDecode(rawJson);

          double mv = 0.0;
          if (data['sensor_mv'] != null) {
            mv = double.tryParse(data['sensor_mv'].toString()) ?? 0.0;
          } else if (data['voltage_v'] != null) {
            mv = (double.tryParse(data['voltage_v'].toString()) ?? 0.0) * 1000.0;
          }

          double uv = double.tryParse(
                  (data['uv_intensity_mw_cm2'] ?? data['uv_index'] ?? '0')
                      .toString()) ??
              (mv / 100.0);

          int rssi = int.tryParse((data['rssi_dbm'] ?? '0').toString()) ?? 0;

          _addReading(mv, uv, rssi, isLive: true);
        } catch (_) {}
      });
    }
  }

  void _addReading(double mv, double uv, int rssi, {required bool isLive}) {
    if (!mounted) return;
    setState(() {
      _latestMv = mv;
      _latestUv = uv;
      _latestRssi = rssi;
      _packetCount++;
      if (isLive) {
        _status = 'Live ESP32 Active (Packets: $_packetCount)';
      }

      _records.add(UVRecord(
        timestamp: DateTime.now(),
        mvMw: mv,
        uvIndex: uv,
        rssi: rssi,
      ));

      if (_records.length > 100) {
        _records.removeAt(0);
      }
    });
  }

  void _toggleDemoStream() {
    setState(() {
      _isSimulating = !_isSimulating;
      if (_isSimulating) {
        _status = 'Demo Stream Active (Every 2s)';
        _simTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          final rng = Random();
          final mv = 12.5 + rng.nextDouble() * 7.0;
          final uv = mv / 100.0;
          _addReading(mv, uv, -51, isLive: false);
        });
      } else {
        _simTimer?.cancel();
        _status = _isConnected ? 'Connected! Listening for ESP32...' : 'Demo Stopped';
      }
    });
  }

  Future<void> _exportCsvAndroid() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data yet! Wait for ESP32 packet or tap Demo.')),
      );
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln('Timestamp,mV/mW,UV_Index');

    final df = DateFormat('yyyy-MM-dd HH:mm:ss');
    for (final row in _records) {
      csv.writeln(
        '${df.format(row.timestamp)},${row.mvMw.toStringAsFixed(2)},${row.uvIndex.toStringAsFixed(3)}',
      );
    }

    try {
      final directory = await getTemporaryDirectory();
      final fileName = 'uv_telemetry_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(csv.toString());

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'ESP32-C3 UV Sensor 3-Column CSV Log',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV Export Error: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF1E293B),
        title: const Text('ESP32 UV Monitor'),
        actions: [
          TextButton.icon(
            onPressed: _toggleDemoStream,
            icon: Icon(
              _isSimulating ? Icons.stop_circle : Icons.play_circle,
              color: _isSimulating ? Colors.amberAccent : Colors.tealAccent,
            ),
            label: Text(
              _isSimulating ? 'Stop' : 'Demo',
              style: const TextStyle(color: Colors.white),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.refresh, color: Colors.tealAccent),
            onPressed: _connectMqttWebSocket,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: (_isConnected || _isSimulating)
                        ? Colors.tealAccent
                        : Colors.orangeAccent,
                  ),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          color: (_isConnected || _isSimulating)
                              ? Colors.greenAccent
                              : Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text(
                      '$_latestRssi dBm',
                      style: const TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _metricCard(
                      'mV / mW Output',
                      '${_latestMv.toStringAsFixed(2)} mV',
                      Colors.cyanAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _metricCard(
                      'UV Index',
                      '${_latestUv.toStringAsFixed(3)} mW/cm²',
                      Colors.amberAccent,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Live Timestamped UV Graph',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                  Text(
                    'Rows: ${_records.length}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.fromLTRB(10, 18, 18, 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF1E293B),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: _records.isEmpty
                      ? const Center(
                          child: Text(
                            'Listening via Secure MQTT WebSockets\nTopic: venkat_iot/sensors/uv/node_01\n\n(Or tap "Demo" at top right to test)',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: Colors.white54),
                          ),
                        )
                      : LineChart(
                          LineChartData(
                            gridData: const FlGridData(show: true, drawVerticalLine: false),
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: 26,
                                  interval: (_records.length > 5) ? (_records.length / 4).floorToDouble() : 1,
                                  getTitlesWidget: (value, meta) {
                                    final idx = value.toInt();
                                    if (idx >= 0 && idx < _records.length) {
                                      return Padding(
                                        padding: const EdgeInsets.only(top: 6.0),
                                        child: Text(
                                          DateFormat('HH:mm:ss').format(_records[idx].timestamp),
                                          style: const TextStyle(fontSize: 9, color: Colors.white60),
                                        ),
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),
                              ),
                            ),
                            lineBarsData: [
                              LineChartBarData(
                                spots: _records
                                    .asMap()
                                    .entries
                                    .map((e) => FlSpot(e.key.toDouble(), e.value.uvIndex))
                                    .toList(),
                                isCurved: true,
                                color: Colors.amberAccent,
                                barWidth: 3,
                                dotData: const FlDotData(show: true),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.teal,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  onPressed: _exportCsvAndroid,
                  icon: const Icon(Icons.download, color: Colors.white),
                  label: const Text(
                    'Export 3-Column CSV (Timestamp, mV/mW, UV_Index)',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _metricCard(String title, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(color: Colors.white60, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}