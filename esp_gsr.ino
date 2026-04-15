#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

// ===== UUIDs =====
#define SERVICE_UUID        "12345678-1234-1234-1234-123456789abc"
#define CHARACTERISTIC_UUID "abcd1234-5678-1234-5678-123456789abc"

// ===== Pin =====
#define EDA_PIN 2

// ===== BLE =====
BLECharacteristic *pCharacteristic;
BLEServer *pServer;
bool deviceConnected = false;

// ===== EDA =====
float baseline = 0;
float prev = 0;

// ===== Activity =====
float activitySum = 0;
float activityScore = 0;

unsigned long startTime = 0;
unsigned long windowStart = 0;
unsigned long lastPrintTime = 0;

// ===== Callbacks =====
class MyServerCallbacks: public BLEServerCallbacks {
  void onConnect(BLEServer* server) {
    deviceConnected = true;
    Serial.println("Connected");
  }

  void onDisconnect(BLEServer* server) {
    deviceConnected = false;
    Serial.println("Disconnected");

    // restart advertising
    delay(200);
    BLEDevice::startAdvertising();
  }
};

void setup() {
  Serial.begin(115200);
  delay(1000);

  analogReadResolution(12);

  // ===== INIT SENSOR =====
  baseline = analogRead(EDA_PIN);
  prev = baseline;

  startTime = millis();
  windowStart = millis();

  // ===== BLE INIT =====
  BLEDevice::init("Heltec_EDA");

  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());

  BLEService *pService = pServer->createService(SERVICE_UUID);

  pCharacteristic = pService->createCharacteristic(
    CHARACTERISTIC_UUID,
    BLECharacteristic::PROPERTY_NOTIFY | 
    BLECharacteristic::PROPERTY_READ
  );

  // for notifications 
  pCharacteristic->addDescriptor(new BLE2902());

  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06); 
  pAdvertising->setMinPreferred(0x12);

  BLEDevice::startAdvertising();

  Serial.println("🚀 BLE Ready");
}

void loop() {

  // ===== SENSOR READ =====
  int raw = analogRead(EDA_PIN);

  // ===== BASELINE =====
  if (millis() - startTime < 5000) {
    baseline = 0.95 * baseline + 0.05 * raw;
  } else {
    baseline = 0.995 * baseline + 0.005 * raw;
  }

  // ===== DELTA =====
  float delta = raw - prev;

  if (delta > 0) {
    activitySum += delta;
  }

  // ===== ACTIVITY SCORE =====
  if (millis() - windowStart >= 2000) {

    float newScore = activitySum / 800.0; 

    if (newScore > 1.0) newScore = 1.0;

    activityScore = 0.7 * activityScore + 0.3 * newScore;

    activitySum = 0;
    windowStart = millis();
  }

  // ===== SEND BLE =====
  if (deviceConnected) {
    String data = String(activityScore, 2);
    pCharacteristic->setValue(data.c_str());
    pCharacteristic->notify();
  }

  // ===== SERIAL (1 sec) =====
  if (millis() - lastPrintTime >= 1000) {
    Serial.print("Activity: ");
    Serial.println(activityScore);
    lastPrintTime = millis();
  }

  prev = raw;

  delay(100); // 10 Hz
}
