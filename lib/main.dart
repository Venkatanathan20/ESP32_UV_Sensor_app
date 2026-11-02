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
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const UVMonitorApp());
}

class UVMonitorApp extends StatelessWidget {
  const UVMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'ESP32-C3 UV Monitor Pro',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B0F19),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF00F5D4),
          secondary: Color(0xFF7B2CBF),
        ),
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

  Map<String, dynamic> toJson() => {
        'ts': timestamp.toIso8601String(),
        'mv': mvMw,
        'uv': uvIndex,
        'rssi': rssi,
      };

  factory UVRecord.fromJson(Map<String, dynamic> json) => UVRecord(
        timestamp: DateTime.parse(json['ts']),
        mvMw: (json['mv'] as num).toDouble(),
        uvIndex: (json['uv'] as num).toDouble(),
        rssi: (json['rssi'] as num).toInt(),
      );
}

class UVMonitorScreen extends StatefulWidget {
  const UVMonitorScreen({super.key});

  @override
  State<UVMonitorScreen> createState() => _UVMonitorScreenState();
}

class _UVMonitorScreenState extends State<UVMonitorScreen> {
  final TextEditingController _ipController =
      TextEditingController(text: '192.168.0.117');

  // Polling & Hardware State
  Timer? _pollTimer;
  bool _isLiveHardware = false;
  bool _isSimulating = false;
  String _status = 'Enter ESP32 IP & tap Connect (10s Interval)';
  int _selectedPollSeconds = 10; // Default 10s interval (adjustable 5s or 10s)

  // Live Telemetry Metrics
  double _latestMv = 0.0;
  double _latestUv = 0.0;
  double _peakUvToday = 0.0;
  int _latestRssi = 0;
  int _packetCount = 0;

  // Threshold & Notification State
  double _uvAlertThreshold = 3.0; // UV >= 3.0 triggers High Alert
  bool _wasHighUvState = false;
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Historical Data & Filtering (Day, Week, Month, Year)
  final List<UVRecord> _liveRecords = [];
  List<UVRecord> _allHistoryRecords = [];
  String _selectedTimeFilter = 'Day'; // 'Day', 'Week', 'Month', 'Year'

  @override
  void initState() {
    super.initState();
    _initNotifications();
    _loadSavedHistory();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _ipController.dispose();
    super.dispose();
  }

  // ================= 1. NOTIFICATIONS SETUP =================
  Future<void> _initNotifications() async {
    const androidSettings =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);
    await _notificationsPlugin.initialize(initSettings);

    final androidImplementation =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidImplementation?.requestNotificationsPermission();
  }

  Future<void> _sendUvNotification({
    required String title,
    required String body,
    required bool isHighAlert,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      isHighAlert ? 'uv_high_channel' : 'uv_safe_channel',
      isHighAlert ? 'High UV Alerts' : 'Safe UV Status',
      channelDescription: 'Notifications for UV safety thresholds',
      importance: Importance.max,
      priority: Priority.high,
      color: isHighAlert ? const Color(0xFFFF0055) : const Color(0xFF00F5D4),
      enableVibration: true,
    );

    final details = NotificationDetails(android: androidDetails);
    await _notificationsPlugin.show(
      isHighAlert ? 101 : 102,
      title,
      body,
      details,
    );
  }

  // ================= 2. LOCAL HISTORY STORAGE =================
  Future<void> _loadSavedHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? savedJson = prefs.getStringList('uv_history_logs');
    if (savedJson != null) {
      setState(() {
        _allHistoryRecords = savedJson
            .map((str) => UVRecord.fromJson(jsonDecode(str)))
            .toList();
        _calculateTodayPeak();
      });
    }
  }

  Future<void> _saveRecordToHistory(UVRecord record) async {
    _allHistoryRecords.add(record);
    // Keep up to 5,000 logs locally for Day/Week/Month/Year analysis
    if (_allHistoryRecords.length > 5000) {
      _allHistoryRecords.removeAt(0);
    }
    final prefs = await SharedPreferences.getInstance();
    final List<String> encoded =
        _allHistoryRecords.map((r) => jsonEncode(r.toJson())).toList();
    await prefs.setStringList('uv_history_logs', encoded);
  }

  void _calculateTodayPeak() {
    final now = DateTime.now();
    double maxUv = 0.0;
    for (final r in _allHistoryRecords) {
      if (r.timestamp.year == now.year &&
          r.timestamp.month == now.month &&
          r.timestamp.day == now.day) {
        if (r.uvIndex > maxUv) maxUv = r.uvIndex;
      }
    }
    _peakUvToday = maxUv;
  }

  // ================= 3. HARDWARE POLLING (10s GAP) =================
  void _toggleHardwareConnection() {
    _pollTimer?.cancel();
    setState(() {
      _isSimulating = false;
      _isLiveHardware = !_isLiveHardware;
    });

    if (_isLiveHardware) {
      final ip = _ipController.text.trim();
      setState(() => _status =
          'Connecting to http://$ip/data (${_selectedPollSeconds}s gap)...');
      _fetchHardwareReading();
      // Poll every 10 seconds (or 5s if toggled) as requested
      _pollTimer = Timer.periodic(
        Duration(seconds: _selectedPollSeconds),
        (_) => _fetchHardwareReading(),
      );
    } else {
      setState(() => _status = 'Stream Stopped');
    }
  }

  Future<void> _fetchHardwareReading() async {
    final ip = _ipController.text.trim();
    try {
      final response = await http
          .get(Uri.parse('http://$ip/data'))
          .timeout(const Duration(milliseconds: 2500));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        double mv = double.tryParse(data['sensor_mv'].toString()) ?? 0.0;
        double uv = double.tryParse(data['uv_index'].toString()) ?? (mv / 100.0);
        int rssi = int.tryParse(data['rssi_dbm'].toString()) ?? 0;

        _addReading(mv, uv, rssi, isLive: true);
      } else {
        if (mounted) {
          setState(() => _status = 'HTTP Error: ${response.statusCode}');
        }
      }
    } catch (e) {
      if (mounted && _liveRecords.isEmpty) {
        setState(() => _status = 'Connection Failed: Check IP / Wi-Fi');
      } else if (mounted) {
        setState(() => _status = 'Packet dropped, retrying in ${_selectedPollSeconds}s...');
      }
    }
  }

  void _addReading(double mv, double uv, int rssi, {required bool isLive}) {
    if (!mounted) return;

    final newRecord = UVRecord(
      timestamp: DateTime.now(),
      mvMw: mv,
      uvIndex: uv,
      rssi: rssi,
    );

    // Check UV Alert State Transitions (High vs Safe)
    if (uv >= _uvAlertThreshold && !_wasHighUvState) {
      _wasHighUvState = true;
      _sendUvNotification(
        title: '⚠️ HIGH UV ALERT! (${uv.toStringAsFixed(2)} mW/cm²)',
        body:
            'UV levels have exceeded your safe threshold (${_uvAlertThreshold.toStringAsFixed(1)}). Seek shade or apply SPF protection!',
        isHighAlert: true,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFFF0055),
          content: Text(
            '⚠️ High UV Alert! Reading: ${uv.toStringAsFixed(2)} mW/cm²',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      );
    } else if (uv < (_uvAlertThreshold - 0.3) && _wasHighUvState) {
      // Hysteresis buffer of 0.3 so it doesn't spam notifications on borderline values
      _wasHighUvState = false;
      _sendUvNotification(
        title: '✅ UV Level Normal & Safe (${uv.toStringAsFixed(2)} mW/cm²)',
        body: 'UV intensity has dropped back to safe levels. It is safe outside!',
        isHighAlert: false,
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF00BBF9),
          content: Text(
            '✅ UV Normal & Safe! Reading: ${uv.toStringAsFixed(2)} mW/cm²',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
        ),
      );
    }

    setState(() {
      _latestMv = mv;
      _latestUv = uv;
      _latestRssi = rssi;
      if (uv > _peakUvToday) _peakUvToday = uv;
      _packetCount++;

      if (isLive) {
        _status =
            'Live ESP32 Active • Every ${_selectedPollSeconds}s (Logs: $_packetCount)';
      }

      _liveRecords.add(newRecord);
      if (_liveRecords.length > 60) {
        _liveRecords.removeAt(0);
      }
    });

    _saveRecordToHistory(newRecord);
  }

  void _toggleDemoStream() {
    _pollTimer?.cancel();
    setState(() {
      _isLiveHardware = false;
      _isSimulating = !_isSimulating;
      if (_isSimulating) {
        _status = 'Demo Stream Active (Every ${_selectedPollSeconds}s)';
        // Generate an immediate reading then follow the 5-10s interval
        _generateDemoPoint();
        _pollTimer = Timer.periodic(
          Duration(seconds: _selectedPollSeconds),
          (_) => _generateDemoPoint(),
        );
      } else {
        _status = 'Demo Stopped';
      }
    });
  }

  void _generateDemoPoint() {
    final rng = Random();
    // Simulate occasional high spikes above 3.0 to test Alert & Table
    final bool spike = rng.nextInt(3) == 0;
    final mv = spike ? (320.0 + rng.nextDouble() * 450.0) : (40.0 + rng.nextDouble() * 180.0);
    final uv = mv / 100.0;
    _addReading(mv, uv, -52, isLive: false);
  }

  // ================= 4. FILTERED HIGH-UV TABLE LOGIC =================
  List<UVRecord> _getFilteredHighUvLogs() {
    final now = DateTime.now();
    return _allHistoryRecords.where((r) {
      // Only show readings where UV was High (>= threshold)
      if (r.uvIndex < _uvAlertThreshold) return false;

      switch (_selectedTimeFilter) {
        case 'Day':
          return r.timestamp.year == now.year &&
              r.timestamp.month == now.month &&
              r.timestamp.day == now.day;
        case 'Week':
          return now.difference(r.timestamp).inDays <= 7;
        case 'Month':
          return r.timestamp.year == now.year && r.timestamp.month == now.month;
        case 'Year':
          return r.timestamp.year == now.year;
        default:
          return true;
      }
    }).toList()
      ..sort((a, b) => b.timestamp.compareTo(a.timestamp)); // Newest first
  }

  // ================= 5. DYNAMIC VIBRANT THEME HELPERS =================
  Map<String, dynamic> _getUvSeverityMeta(double uv) {
    if (uv < 2.0) {
      return {
        'label': 'LOW • SAFE',
        'advice': 'No protection needed. Safe to be outdoors!',
        'color': const Color(0xFF00F5D4),
        'gradient': [const Color(0xFF00F5D4), const Color(0xFF00BBF9)],
      };
    } else if (uv < 5.0) {
      return {
        'label': 'MODERATE • CAUTION',
        'advice': 'Wear sunglasses & apply SPF 30+ sunscreen.',
        'color': const Color(0xFFFEE440),
        'gradient': [const Color(0xFFFEE440), const Color(0xFFF15BB5)],
      };
    } else if (uv < 8.0) {
      return {
        'label': 'HIGH • SEEK SHADE',
        'advice': 'Reduce midday sun exposure. Hat & SPF required!',
        'color': const Color(0xFFFF9E00),
        'gradient': [const Color(0xFFFF9E00), const Color(0xFFFF0055)],
      };
    } else {
      return {
        'label': 'EXTREME • DANGER',
        'advice': 'Avoid direct sun! High risk of rapid skin burn.',
        'color': const Color(0xFFFF0055),
        'gradient': [const Color(0xFFFF0055), const Color(0xFF7B2CBF)],
      };
    }
  }

  Future<void> _exportCsvAndroid() async {
    if (_allHistoryRecords.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No data yet! Connect ESP32 or tap Demo.')),
      );
      return;
    }

    final StringBuffer csv = StringBuffer();
    csv.writeln('Timestamp,mV/mW,UV_Index,Status');

    final df = DateFormat('yyyy-MM-dd HH:mm:ss');
    for (final row in _allHistoryRecords) {
      final status = row.uvIndex >= _uvAlertThreshold ? 'HIGH_ALERT' : 'SAFE';
      csv.writeln(
        '${df.format(row.timestamp)},${row.mvMw.toStringAsFixed(2)},${row.uvIndex.toStringAsFixed(3)},$status',
      );
    }

    try {
      final directory = await getTemporaryDirectory();
      final fileName =
          'uv_telemetry_${DateFormat('yyyyMMdd_HHmmss').format(DateTime.now())}.csv';
      final file = File('${directory.path}/$fileName');
      await file.writeAsString(csv.toString());

      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'ESP32-C3 UV Sensor Full History CSV Log',
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('CSV Export Error: $e')),
      );
    }
  }

  // ================= 6. MAIN UI BUILDER =================
  @override
  Widget build(BuildContext context) {
    final severity = _getUvSeverityMeta(_latestUv);
    final Color activeColor = severity['color'] as Color;
    final List<Color> bannerGradient = severity['gradient'] as List<Color>;
    final highUvLogs = _getFilteredHighUvLogs();

    return Scaffold(
      appBar: AppBar(
        elevation: 0,
        backgroundColor: const Color(0xFF131B2E),
        title: const Row(
          children: [
            Icon(Icons.wb_sunny_rounded, color: Color(0xFFFEE440), size: 22),
            SizedBox(width: 8),
            Text(
              'UV Guardian Pro',
              style: TextStyle(fontWeight: FontWeight.w800, fontSize: 18),
            ),
          ],
        ),
        actions: [
          // Toggle between 5s and 10s interval
          PopupMenuButton<int>(
            tooltip: 'Sampling Interval',
            icon: const Icon(Icons.timer_outlined, color: Color(0xFF00F5D4)),
            onSelected: (seconds) {
              setState(() => _selectedPollSeconds = seconds);
              if (_isLiveHardware) {
                _toggleHardwareConnection();
                _toggleHardwareConnection();
              } else if (_isSimulating) {
                _toggleDemoStream();
                _toggleDemoStream();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 5, child: Text('Poll Every 5 Seconds')),
              const PopupMenuItem(value: 10, child: Text('Poll Every 10 Seconds')),
            ],
          ),
          TextButton.icon(
            onPressed: _toggleDemoStream,
            icon: Icon(
              _isSimulating ? Icons.stop_circle : Icons.auto_graph_rounded,
              color: _isSimulating ? const Color(0xFFFF0055) : const Color(0xFF00F5D4),
            ),
            label: Text(
              _isSimulating ? 'Stop' : 'Demo',
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(14.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1. CONNECTION & IP BAR
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFF151F32),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _ipController,
                            style: const TextStyle(
                                color: Colors.white, fontWeight: FontWeight.bold),
                            decoration: InputDecoration(
                              labelText: 'ESP32 Local IP (from OLED)',
                              labelStyle: const TextStyle(color: Colors.white60),
                              prefixIcon: const Icon(Icons.router_rounded,
                                  color: Color(0xFF00F5D4)),
                              filled: true,
                              fillColor: const Color(0xFF0B0F19),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                                borderSide: BorderSide.none,
                              ),
                              isDense: true,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isLiveHardware
                                ? const Color(0xFFFF0055)
                                : const Color(0xFF00F5D4),
                            foregroundColor:
                                _isLiveHardware ? Colors.white : Colors.black,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 18, vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: _toggleHardwareConnection,
                          child: Text(
                            _isLiveHardware ? 'Stop' : 'Connect',
                            style: const TextStyle(fontWeight: FontWeight.w900),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 8,
                                height: 8,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: (_isLiveHardware || _isSimulating)
                                      ? const Color(0xFF00F5D4)
                                      : Colors.orangeAccent,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _status,
                                  style: const TextStyle(
                                      color: Colors.white70, fontSize: 11),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          'Interval: ${_selectedPollSeconds}s | $_latestRssi dBm',
                          style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 2. VIBRANT HERO UV STATUS BANNER
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      bannerGradient[0].withOpacity(0.25),
                      bannerGradient[1].withOpacity(0.10),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(color: activeColor.withOpacity(0.6), width: 1.5),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: activeColor.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _latestUv >= _uvAlertThreshold
                            ? Icons.warning_amber_rounded
                            : Icons.verified_user_rounded,
                        color: activeColor,
                        size: 32,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            severity['label'] as String,
                            style: TextStyle(
                              color: activeColor,
                              fontWeight: FontWeight.w900,
                              fontSize: 14,
                              letterSpacing: 0.8,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            severity['advice'] as String,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w500),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),

              // 3. THREE VIBRANT METRIC CARDS (mV, Live UV, Peak Today)
              Row(
                children: [
                  Expanded(
                    child: _vibrantMetricCard(
                      title: 'Sensor Output',
                      value: '${_latestMv.toStringAsFixed(1)} mV',
                      icon: Icons.bolt_rounded,
                      accent: const Color(0xFF00BBF9),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _vibrantMetricCard(
                      title: 'Live UV Intensity',
                      value: '${_latestUv.toStringAsFixed(2)} mW',
                      icon: Icons.wb_iridescent_rounded,
                      accent: activeColor,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _vibrantMetricCard(
                      title: 'Today Peak UV',
                      value: '${_peakUvToday.toStringAsFixed(2)} mW',
                      icon: Icons.trending_up_rounded,
                      accent: const Color(0xFFF15BB5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // 4. CUSTOM ALERT THRESHOLD SLIDER
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF151F32),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.notifications_active_rounded,
                        color: Color(0xFFFEE440), size: 20),
                    const SizedBox(width: 10),
                    const Text(
                      'High UV Alert Threshold:',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    Expanded(
                      child: Slider(
                        value: _uvAlertThreshold,
                        min: 1.0,
                        max: 10.0,
                        divisions: 18,
                        activeColor: const Color(0xFFFF0055),
                        label: _uvAlertThreshold.toStringAsFixed(1),
                        onChanged: (val) {
                          setState(() => _uvAlertThreshold = val);
                        },
                      ),
                    ),
                    Text(
                      '${_uvAlertThreshold.toStringAsFixed(1)} mW',
                      style: const TextStyle(
                        color: Color(0xFFFF0055),
                        fontWeight: FontWeight.w900,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // 5. LIVE TIMESTAMPED UV GRAPH
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'Live UV Intensity Trend',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                  ),
                  Text(
                    'Session Points: ${_liveRecords.length}',
                    style: const TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                height: 220,
                padding: const EdgeInsets.fromLTRB(10, 18, 18, 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF151F32),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: _liveRecords.isEmpty
                    ? const Center(
                        child: Text(
                          'Tap "Connect" or "Demo" to start 10-second live UV plotting',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white54, fontSize: 12),
                        ),
                      )
                    : LineChart(
                        LineChartData(
                          gridData: FlGridData(
                            show: true,
                            drawVerticalLine: false,
                            getDrawingHorizontalLine: (value) => FlLine(
                              color: Colors.white.withOpacity(0.06),
                              strokeWidth: 1,
                            ),
                          ),
                          borderData: FlBorderData(show: false),
                          extraLinesData: ExtraLinesData(
                            horizontalLines: [
                              HorizontalLine(
                                y: _uvAlertThreshold,
                                color: const Color(0xFFFF0055).withOpacity(0.8),
                                strokeWidth: 1.5,
                                dashArray: [6, 4],
                                label: HorizontalLineLabel(
                                  show: true,
                                  alignment: Alignment.topRight,
                                  style: const TextStyle(
                                    color: Color(0xFFFF0055),
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                  ),
                                  labelResolver: (_) => 'Alert Threshold',
                                ),
                              ),
                            ],
                          ),
                          titlesData: FlTitlesData(
                            topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false)),
                            rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false)),
                            bottomTitles: AxisTitles(
                              sideTitles: SideTitles(
                                showTitles: true,
                                reservedSize: 24,
                                interval: (_liveRecords.length > 5)
                                    ? (_liveRecords.length / 4).floorToDouble()
                                    : 1,
                                getTitlesWidget: (value, meta) {
                                  final idx = value.toInt();
                                  if (idx >= 0 && idx < _liveRecords.length) {
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 6.0),
                                      child: Text(
                                        DateFormat('HH:mm:ss')
                                            .format(_liveRecords[idx].timestamp),
                                        style: const TextStyle(
                                            fontSize: 9, color: Colors.white60),
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
                              spots: _liveRecords
                                  .asMap()
                                  .entries
                                  .map((e) => FlSpot(
                                      e.key.toDouble(), e.value.uvIndex))
                                  .toList(),
                              isCurved: true,
                              color: activeColor,
                              barWidth: 3.5,
                              dotData: const FlDotData(show: true),
                              belowBarData: BarAreaData(
                                show: true,
                                gradient: LinearGradient(
                                  colors: [
                                    activeColor.withOpacity(0.35),
                                    activeColor.withOpacity(0.0),
                                  ],
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              const SizedBox(height: 20),

              // 6. HIGH UV LOG TABLE (DAY / WEEK / MONTH / YEAR FILTER)
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.history_toggle_off_rounded,
                          color: Color(0xFFFF0055), size: 20),
                      SizedBox(width: 6),
                      Text(
                        'High UV Peak Exposure Log',
                        style:
                            TextStyle(fontSize: 15, fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  Text(
                    '${highUvLogs.length} Events',
                    style: const TextStyle(
                        color: Color(0xFFFF0055),
                        fontSize: 12,
                        fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Filter Chips: Day, Week, Month, Year
              Row(
                children: ['Day', 'Week', 'Month', 'Year'].map((period) {
                  final bool isSelected = _selectedTimeFilter == period;
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3.0),
                      child: ChoiceChip(
                        label: SizedBox(
                          width: double.infinity,
                          child: Text(
                            period,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 12,
                              color: isSelected ? Colors.black : Colors.white70,
                            ),
                          ),
                        ),
                        selected: isSelected,
                        selectedColor: const Color(0xFF00F5D4),
                        backgroundColor: const Color(0xFF151F32),
                        onSelected: (_) {
                          setState(() => _selectedTimeFilter = period);
                        },
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),

              // High UV Table Container
              Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: const Color(0xFF151F32),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: highUvLogs.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Center(
                          child: Text(
                            'No High UV events (>= ${_uvAlertThreshold.toStringAsFixed(1)} mW/cm²) recorded for this $_selectedTimeFilter.\nStay safe!',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 12),
                          ),
                        ),
                      )
                    : SizedBox(
                        height: 220,
                        child: SingleChildScrollView(
                          scrollDirection: Axis.vertical,
                          child: DataTable(
                            columnSpacing: 18,
                            headingRowColor: WidgetStateProperty.all(
                                const Color(0xFF1E293B)),
                            columns: const [
                              DataColumn(
                                label: Text('Date',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                              ),
                              DataColumn(
                                label: Text('Time',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                              ),
                              DataColumn(
                                label: Text('UV (mW)',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                              ),
                              DataColumn(
                                label: Text('Status',
                                    style: TextStyle(
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12)),
                              ),
                            ],
                            rows: highUvLogs.take(50).map((log) {
                              final isExtreme = log.uvIndex >= 6.0;
                              return DataRow(
                                cells: [
                                  DataCell(Text(
                                    DateFormat('dd MMM yyyy')
                                        .format(log.timestamp),
                                    style: const TextStyle(fontSize: 11),
                                  )),
                                  DataCell(Text(
                                    DateFormat('hh:mm:ss a')
                                        .format(log.timestamp),
                                    style: const TextStyle(
                                        fontSize: 11,
                                        color: Color(0xFF00F5D4),
                                        fontWeight: FontWeight.w600),
                                  )),
                                  DataCell(Text(
                                    log.uvIndex.toStringAsFixed(2),
                                    style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.amberAccent),
                                  )),
                                  DataCell(
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: (isExtreme
                                                ? const Color(0xFFFF0055)
                                                : const Color(0xFFFF9E00))
                                            .withOpacity(0.2),
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Text(
                                        isExtreme ? 'EXTREME' : 'HIGH UV',
                                        style: TextStyle(
                                          color: isExtreme
                                              ? const Color(0xFFFF0055)
                                              : const Color(0xFFFF9E00),
                                          fontWeight: FontWeight.bold,
                                          fontSize: 10,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            }).toList(),
                          ),
                        ),
                      ),
              ),
              const SizedBox(height: 16),

              // 7. EXPORT CSV BUTTON
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF7B2CBF),
                    padding: const EdgeInsets.symmetric(vertical: 15),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                  onPressed: _exportCsvAndroid,
                  icon: const Icon(Icons.download_rounded, color: Colors.white),
                  label: const Text(
                    'Export Full History CSV (Timestamp, mV, UV, Status)',
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _vibrantMetricCard({
    required String title,
    required String value,
    required IconData icon,
    required Color accent,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFF151F32),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withOpacity(0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: accent, size: 18),
          const SizedBox(height: 6),
          Text(title,
              style: const TextStyle(color: Colors.white60, fontSize: 10)),
          const SizedBox(height: 3),
          Text(
            value,
            style: TextStyle(
                color: accent, fontSize: 15, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}