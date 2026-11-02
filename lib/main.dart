import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
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
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.0.117');

  Timer? _pollTimer;
  bool _isLiveHardware = false;
  bool _isSimulating = false;
  String _status = 'Enter ESP32 IP from OLED & tap Connect';

  double _latestMv = 0.0;
  double _latestUv = 0.0;
  int _latestRssi = 0;
  int _packetCount = 0;
  final List<UVRecord> _records = [];

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  void _toggleHardwareConnection() {
    _pollTimer?.cancel();
    setState(() {
      _isSimulating = false;
      _isLiveHardware = !_isLiveHardware;
    });

    if (_isLiveHardware) {
      final ip = _ipController.text.trim();
      setState(() => _status = 'Polling ESP32 at http://$ip/data ...');
      _fetchHardwareReading();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        _fetchHardwareReading();
      });
    } else {
      setState(() => _status = 'Polling Stopped');
    }
  }

  Future<void> _fetchHardwareReading() async {
    final ip = _ipController.text.trim();
    try {
      final response = await http
          .get(Uri.parse('http://$ip/data'))
          .timeout(const Duration(seconds: 3));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        double mv = double.tryParse(data['sensor_mv'].toString()) ?? 0.0;
        double uv = double.tryParse(data['uv_index'].toString()) ?? (mv / 100.0);
        int rssi = int.tryParse(data['rssi_dbm'].toString()) ?? 0;

        _addReading(mv, uv, rssi, isLive: true);
      } else {
        setState(() => _status = 'HTTP Error ${response.statusCode}');
      }
    } catch (e) {
      setState(() => _status = 'Error: Check if phone & ESP32 share same Wi-Fi');
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
        _status = 'Live ESP32 Connected! (Packets: $_packetCount)';
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
    _pollTimer?.cancel();
    setState(() {
      _isLiveHardware = false;
      _isSimulating = !_isSimulating;
      if (_isSimulating) {
        _status = 'Demo Stream Active (Every 2s)';
        _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) {
          final rng = Random();
          final mv = 12.5 + rng.nextDouble() * 7.0;
          final uv = mv / 100.0;
          _addReading(mv, uv, -50, isLive: false);
        });
      } else {
        _status = 'Demo Stopped';
      }
    });
  }

  Future<void> _exportCsvAndroid() async {
    if (_records.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data yet! Connect ESP32 or tap Demo.')),
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
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _ipController,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: 'ESP32 IP Address (from OLED)',
                          labelStyle: TextStyle(color: Colors.white70),
                          prefixIcon: Icon(Icons.wifi, color: Colors.tealAccent),
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isLiveHardware ? Colors.redAccent : Colors.teal,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                      ),
                      onPressed: _toggleHardwareConnection,
                      child: Text(
                        _isLiveHardware ? 'Disconnect' : 'Connect',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        _status,
                        style: TextStyle(
                          color: (_isLiveHardware || _isSimulating) ? Colors.greenAccent : Colors.orangeAccent,
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Text('$_latestRssi dBm', style: const TextStyle(color: Colors.white70, fontSize: 12)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _metricCard('mV / Output', '${_latestMv.toStringAsFixed(2)} mV', Colors.cyanAccent),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _metricCard('UV Index', '${_latestUv.toStringAsFixed(3)} mW/cm²', Colors.amberAccent),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Live Timestamped UV Graph', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                  Text('Rows: ${_records.length}', style: const TextStyle(color: Colors.white60, fontSize: 12)),
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
                            'Enter ESP32 IP Address above & tap Connect,\n- OR - Tap "Demo" at top right to test graph & CSV!',
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
                                spots: _records.asMap().entries.map((e) => FlSpot(e.key.toDouble(), e.value.uvIndex)).toList(),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _exportCsvAndroid,
                  icon: const Icon(Icons.download, color: Colors.white),
                  label: const Text(
                    'Export 3-Column CSV (Timestamp, mV/mW, UV_Index)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.white),
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
      path: const EdgeInsets.all(14), // fixed syntax
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
          Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }
}