/*
 * BÓVEDA DE SEGURIDAD - FASE 3: HUELLA DIGITAL (SOLO AS608 + FPGA)
 * ESP32 + sensor AS608 + FPGA DE10-Lite
 *
 * Conexiones ESP32 <-> FPGA:
 *   - GPIO 18 (IN)  <- FPGA PIN_W12  (HAB_HUELLA)
 *   - GPIO 19 (OUT) -> FPGA PIN_AB12 (HUELLA_OK)
 *   - GPIO 21 (OUT) -> FPGA PIN_AB11 (HUELLA_ERR)
 *   - GND común
 *
 * Conexiones AS608 <-> ESP32:
 *   - VCC -> 3.3V | GND -> GND
 *   - TX del sensor -> GPIO 16 (RX2)
 *   - RX del sensor -> GPIO 17 (TX2)
 *
 * MODO REGISTRO (Monitor Serie a 115200 baudios): enviar 'r'
 */

#include <Adafruit_Fingerprint.h>

// ===================== PINES =====================
#define PIN_AS608_RX    16   // RX2 de la ESP32  <- TX del AS608
#define PIN_AS608_TX    17   // TX2 de la ESP32  -> RX del AS608
#define PIN_HAB_HUELLA  18   // ENTRADA desde FPGA (PIN_W12)
#define PIN_HUELLA_OK   19   // SALIDA hacia FPGA  (PIN_AB12)
#define PIN_HUELLA_ERR  21   // SALIDA hacia FPGA  (PIN_AB11)

// ===================== AJUSTES =====================
const uint16_t MIN_CONFIANZA         = 40;    // confianza mínima para aceptar
const uint16_t PULSO_MS              = 300;   // duración de pulsos OK / ERR hacia FPGA
const uint16_t ESPERA_POST_ERROR_MS  = 1200;  // pausa tras un error antes de volver a leer
const uint32_t TIMEOUT_REGISTRO_MS   = 20000; // tiempo máx. esperando el dedo al registrar

// ===================== OBJETOS =====================
HardwareSerial mySerial(2);
Adafruit_Fingerprint finger = Adafruit_Fingerprint(&mySerial);
uint16_t maxId = 127;

// Prototipos
void revisarSerial();
void leerYValidar();
void huellaOk();
void huellaError();
void registrarHuella();

// ===================== UTILIDADES =====================
bool habilitado() {
  if (digitalRead(PIN_HAB_HUELLA) == LOW) return false;
  delay(5);
  return digitalRead(PIN_HAB_HUELLA) == HIGH;
}

void pulso(uint8_t pin) {
  digitalWrite(pin, HIGH);
  delay(PULSO_MS);
  digitalWrite(pin, LOW);
}

// Espera a que se retire el dedo (o a que la FPGA baje HAB_HUELLA)
void esperarSinDedoHab() {
  while (habilitado() && finger.getImage() != FINGERPRINT_NOFINGER) delay(50);
  delay(200);
}

// ===================== SETUP =====================
void setup() {
  Serial.begin(115200);
  delay(100);

  pinMode(PIN_HAB_HUELLA, INPUT_PULLDOWN);
  pinMode(PIN_HUELLA_OK, OUTPUT);   digitalWrite(PIN_HUELLA_OK, LOW);
  pinMode(PIN_HUELLA_ERR, OUTPUT);  digitalWrite(PIN_HUELLA_ERR, LOW);

  Serial.println(F("\n\n=== Boveda: modulo de HUELLA ==="));
  mySerial.begin(57600, SERIAL_8N1, PIN_AS608_RX, PIN_AS608_TX);

  while (!finger.verifyPassword()) {
    Serial.println(F("ERROR: no se encuentra el AS608. Revisa TX/RX y alimentacion."));
    delay(2000);
  }
  Serial.println(F("Sensor AS608 detectado."));

  finger.getParameters();
  if (finger.capacity > 0) maxId = finger.capacity;
  finger.getTemplateCount();
  Serial.print(F("Huellas guardadas: ")); Serial.print(finger.templateCount);
  Serial.print(F(" | Capacidad: "));      Serial.println(maxId);
  if (finger.templateCount == 0) Serial.println(F("AVISO: no hay huellas. Envia 'r' para registrar."));
  Serial.println(F("Envia 'r' para registrar una huella."));
}

// ===================== LOOP =====================
void loop() {
  static bool habPrev = false;

  revisarSerial();

  bool hab = habilitado();
  if (hab != habPrev) {
    habPrev = hab;
    Serial.println(hab ? F("[FPGA] HAB_HUELLA=1 -> lector ACTIVO")
                       : F("[FPGA] HAB_HUELLA=0 -> lector en REPOSO"));
  }
  if (!hab) { delay(20); return; }

  leerYValidar();
}

// ===================== VALIDACIÓN =====================
void leerYValidar() {
  uint8_t p = finger.getImage();
  if (p != FINGERPRINT_OK) { delay(30); return; }

  p = finger.image2Tz();
  if (p != FINGERPRINT_OK) {
    Serial.println(F("Lectura ilegible -> ERROR"));
    huellaError();
    return;
  }

  p = finger.fingerSearch();
  if (p == FINGERPRINT_OK && finger.confidence >= MIN_CONFIANZA) {
    Serial.print(F("ACCESO CONCEDIDO | ID #")); Serial.print(finger.fingerID);
    Serial.print(F(" | confianza ")); Serial.println(finger.confidence);
    huellaOk();
  } else if (p == FINGERPRINT_OK || p == FINGERPRINT_NOTFOUND) {
    Serial.print(F("ACCESO DENEGADO | "));
    if (p == FINGERPRINT_OK) { Serial.print(F("confianza baja: ")); Serial.println(finger.confidence); }
    else                      Serial.println(F("huella no registrada"));
    huellaError();
  } else {
    Serial.println(F("Error de comunicacion con el sensor (se reintenta)"));
    delay(100);
  }
}

void huellaOk() {
  pulso(PIN_HUELLA_OK);   // Avisa a la FPGA (PIN_AB12)
  esperarSinDedoHab();
}

void huellaError() {
  uint32_t t0 = millis();
  pulso(PIN_HUELLA_ERR);  // Avisa a la FPGA (PIN_AB11)

  // Espera 1.2 s vigilando si la FPGA bajó HAB_HUELLA (bloqueo por 3er fallo)
  while (millis() - t0 < ESPERA_POST_ERROR_MS) {
    if (!habilitado()) {
      Serial.println(F("BLOQUEO detectado (HAB_HUELLA=0): volviendo a reposo"));
      return;
    }
    delay(10);
  }

  esperarSinDedoHab();
}

// ===================== REGISTRO (por Monitor Serie) =====================
void limpiarSerial() {
  delay(50);
  while (Serial.available()) Serial.read();
}

String leerLinea() {
  String s = "";
  uint32_t t0 = millis();
  while (millis() - t0 < 30000) {
    while (Serial.available()) {
      char c = Serial.read();
      if (c == '\n' || c == '\r') { if (s.length()) return s; }
      else s += c;
    }
    delay(5);
  }
  return "";
}

bool esperarDedo(uint32_t timeout) {
  uint32_t t0 = millis();
  while (millis() - t0 < timeout) {
    if (finger.getImage() == FINGERPRINT_OK) return true;
    delay(20);
  }
  return false;
}

bool esperarSinDedo(uint32_t timeout) {
  uint32_t t0 = millis();
  while (millis() - t0 < timeout) {
    if (finger.getImage() == FINGERPRINT_NOFINGER) return true;
    delay(20);
  }
  return false;
}

void revisarSerial() {
  if (!Serial.available()) return;
  char c = Serial.read();
  if (c == 'r' || c == 'R') registrarHuella();
  else if (c != '\n' && c != '\r' && c != ' ') Serial.println(F("Comando no valido. Envia 'r' para registrar."));
}

void registrarHuella() {
  Serial.println(F("\n=== MODO REGISTRO ==="));
  Serial.print(F("Escribe el ID (1 a ")); Serial.print(maxId); Serial.println(F(") y Enter:"));
  limpiarSerial();
  int id = leerLinea().toInt();
  if (id < 1 || id > (int)maxId) { Serial.println(F("ID invalido. Registro cancelado.")); return; }

  Serial.print(F("Registrando ID #")); Serial.println(id);
  Serial.println(F("Pon el dedo en el sensor..."));
  if (!esperarDedo(TIMEOUT_REGISTRO_MS))             { Serial.println(F("Tiempo agotado.")); return; }
  if (finger.image2Tz(1) != FINGERPRINT_OK)          { Serial.println(F("Error procesando imagen 1. Reintenta.")); return; }

  Serial.println(F("Quita el dedo..."));
  delay(1000);
  if (!esperarSinDedo(TIMEOUT_REGISTRO_MS))          { Serial.println(F("Tiempo agotado.")); return; }

  Serial.println(F("Pon el MISMO dedo otra vez..."));
  if (!esperarDedo(TIMEOUT_REGISTRO_MS))             { Serial.println(F("Tiempo agotado.")); return; }
  if (finger.image2Tz(2) != FINGERPRINT_OK)          { Serial.println(F("Error procesando imagen 2. Reintenta.")); return; }

  if (finger.createModel() != FINGERPRINT_OK)        { Serial.println(F("Las dos lecturas no coinciden. Reintenta.")); return; }
  if (finger.storeModel(id) != FINGERPRINT_OK)       { Serial.println(F("Error al guardar en la memoria del sensor.")); return; }

  finger.getTemplateCount();
  Serial.print(F("EXITO: huella guardada en ID #")); Serial.print(id);
  Serial.print(F(" | Total guardadas: ")); Serial.println(finger.templateCount);
  Serial.println(F("Quita el dedo. Volviendo a modo normal."));
  esperarSinDedo(5000);
}