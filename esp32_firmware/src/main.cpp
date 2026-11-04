#include <Arduino.h>
#include <WiFi.h>
#include <WebServer.h>
#include <PubSubClient.h>
#include <ArduinoJson.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

const char* WIFI_SSID     = "IB707";
const char* WIFI_PASSWORD = "IB707IB707";

const char* MQTT_BROKER   = "broker.hivemq.com";
const int   MQTT_PORT     = 1883;
const char* MQTT_TOPIC    = "venkat_iot/sensors/uv/node_01";

#define UV_SENSOR_PIN 2
#define I2C_SDA_PIN   8
#define I2C_SCL_PIN   9
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT 64

Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);
WebServer server(80);
WiFiClient espClient;
PubSubClient mqttClient(espClient);

unsigned long lastSampleMillis = 0;
const unsigned long SAMPLE_INTERVAL_MS = 2000;
uint32_t packetSeq = 0;

float currentMv = 0.0f;
float currentUvIndex = 0.0f;
int currentRssi = 0;

float readAveragedMilliVolts() {
  uint32_t totalMv = 0;
  for (int i = 0; i < 32; i++) {
    totalMv += analogReadMilliVolts(UV_SENSOR_PIN);
  }
  return totalMv / 32.0f;
}

void handleJsonData() {
  server.sendHeader("Access-Control-Allow-Origin", "*");
  server.sendHeader("Access-Control-Allow-Methods", "GET, OPTIONS");
  server.sendHeader("Access-Control-Allow-Headers", "*");

  JsonDocument doc;
  doc["seq"] = packetSeq;
  doc["sensor_mv"] = serialized(String(currentMv, 2));
  doc["uv_index"] = serialized(String(currentUvIndex, 3));
  doc["rssi_dbm"] = currentRssi;
  doc["ip"] = WiFi.localIP().toString();

  String response;
  serializeJson(doc, response);
  server.send(200, "application/json", response);
}

void connectWiFi() {
  WiFi.mode(WIFI_STA);
  WiFi.setTxPower(WIFI_POWER_8_5dBm);
  WiFi.begin(WIFI_SSID, WIFI_PASSWORD);

  while (WiFi.status() != WL_CONNECTED) {
    delay(500);
    display.clearDisplay();
    display.setTextSize(1);
    display.setTextColor(SSD1306_WHITE);
    display.setCursor(0, 0);
    display.println("Connecting Wi-Fi...");
    display.print("SSID: ");
    display.println(WIFI_SSID);
    display.display();
  }

  display.clearDisplay();
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println("ESP32 Connected!");
  display.setCursor(0, 16);
  display.println("IP Address:");
  display.setCursor(0, 32);
  display.println(WiFi.localIP().toString());
  display.display();
  delay(3000);
}

void setup() {
  Serial.begin(115200);
  analogReadResolution(12);

  Wire.begin(I2C_SDA_PIN, I2C_SCL_PIN);
  display.begin(SSD1306_SWITCHCAPVCC, 0x3C);

  connectWiFi();

  server.on("/data", HTTP_GET, handleJsonData);
  server.on("/data", HTTP_OPTIONS, []() {
    server.sendHeader("Access-Control-Allow-Origin", "*");
    server.send(204);
  });
  server.begin();

  mqttClient.setServer(MQTT_BROKER, MQTT_PORT);
}

void loop() {
  server.handleClient();

  if (WiFi.status() != WL_CONNECTED) {
    connectWiFi();
  }

  if (!mqttClient.connected()) {
    String clientId = "ESP32C3_UV_" + String(random(0xffff), HEX);
    mqttClient.connect(clientId.c_str());
  }
  mqttClient.loop();

  unsigned long now = millis();
  if (now - lastSampleMillis >= SAMPLE_INTERVAL_MS) {
    lastSampleMillis = now;
    packetSeq++;

    currentMv = readAveragedMilliVolts();
    currentUvIndex = currentMv / 100.0f;
    currentRssi = WiFi.RSSI();

    JsonDocument doc;
    doc["seq"] = packetSeq;
    doc["sensor_mv"] = serialized(String(currentMv, 2));
    doc["uv_index"] = serialized(String(currentUvIndex, 3));
    doc["rssi_dbm"] = currentRssi;

    char jsonBuffer[256];
    serializeJson(doc, jsonBuffer);
    mqttClient.publish(MQTT_TOPIC, jsonBuffer);

    display.clearDisplay();
    display.setTextSize(1);
    display.setCursor(0, 0);
    display.printf("IP:%s\n", WiFi.localIP().toString().c_str());
    display.println("--------------------");
    display.printf("mV/mW:  %.2f\n", currentMv);
    display.printf("UV Idx: %.3f\n", currentUvIndex);
    display.printf("RSSI:   %d dBm (#%lu)\n", currentRssi, packetSeq);
    display.display();
  }
}
