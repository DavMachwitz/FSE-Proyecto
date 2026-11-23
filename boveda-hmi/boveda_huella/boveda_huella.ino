/*
 * BÓVEDA DE SEGURIDAD - FASE 3: HUELLA DIGITAL CON VALIDACIÓN CRUZADA
 * ESP32 + sensor AS608 + FPGA DE10-Lite
 *
 * Conexiones ESP32 <-> FPGA:
 *   - GPIO 18 (IN)  <- FPGA PIN_W12  (HAB_HUELLA)
 *   - GPIO 19 (OUT) -> FPGA PIN_AB12 (HUELLA_OK)
 *   - GPIO 21 (OUT) -> FPGA PIN_AB11 (HUELLA_ERR  -> 'E' error general)
 *   - GPIO 25 (OUT) -> FPGA PIN_AA12 (HUELLA_CRUZ -> 'C' error cruzado)
 *   - GPIO 22 (IN)  <- FPGA PIN_AB10 (USER_ID bit 0)
 *   - GPIO 23 (IN)  <- FPGA PIN_AA11 (USER_ID bit 1)
 *   - GND común
 */

#include <Adafruit_Fingerprint.h>

// ===================== PINES =====================
#define PIN_AS608_RX    16
#define PIN_AS608_TX    17
#define PIN_HAB_HUELLA  18
#define PIN_HUELLA_OK   19
#define PIN_HUELLA_ERR  21
#define PIN_USER_BIT0   22
#define PIN_USER_BIT1   23
#define PIN_HUELLA_CRUZ 25

// ===================== ASOCIACIÓN ESTRICTA USUARIO <-> ID HUELLA =====================
const uint16_t ID_HUELLA_SANTIAGO = 101; // Código FPGA: 01 (1)
const uint16_t ID_HUELLA_DAVID    = 102; // Código FPGA: 10 (2)
const uint16_t ID_HUELLA_ABNER    = 103; // Código FPGA: 11 (3)

// ===================== AJUSTES =====================
const uint16_t MIN_CONFIANZA         = 40;
const uint16_t PULSO_MS              = 300;
const uint16_t ESPERA_POST_ERROR_MS  = 1200;
const uint32_t TIMEOUT_REGISTRO_MS   = 20000;

HardwareSerial mySerial(2);
Adafruit_Fingerprint finger = Adafruit_Fingerprint(&mySerial);
uint16_t maxId = 127;

// ===================== UTILIDADES =====================
bool habilitado() {
  if (digitalRead(PIN_HAB_HUELLA) == LOW) return false;
  delay(5);
  return digitalRead(PIN_HAB_HUELLA) == HIGH;
}

uint8_t leerUsuarioEsperado() {
  uint8_t b0 = digitalRead(PIN_USER_BIT0) == HIGH ? 1 : 0;
  uint8_t b1 = digitalRead(PIN_USER_BIT1) == HIGH ? 1 : 0;
  return (b1 << 1) | b0; // 1=Santiago, 2=David, 3=Abner
}

uint16_t obtenerIdHuellaEsperado(uint8_t userCode) {
  switch (userCode) {
    case 1: return ID_HUELLA_SANTIAGO;
    case 2: return ID_HUELLA_DAVID;
    case 3: return ID_HUELLA_ABNER;
    default: return 0;
  }
}

void pulso(uint8_t pin) {
  digitalWrite(pin, HIGH);
  delay(PULSO_MS);
  digitalWrite(pin, LOW);
}

void esperarSinDedoHab() {
  while (habilitado() && finger.getImage() != FINGERPRINT_NOFINGER) delay(50);
  delay(200);
}

// ===================== SETUP =====================
void setup() {
  Serial.begin(115200);
  delay(100);

  pinMode(PIN_HAB_HUELLA,  INPUT_PULLDOWN);
  pinMode(PIN_USER_BIT0,   INPUT_PULLDOWN);
  pinMode(PIN_USER_BIT1,   INPUT_PULLDOWN);
  pinMode(PIN_HUELLA_OK,   OUTPUT); digitalWrite(PIN_HUELLA_OK,   LOW);
  pinMode(PIN_HUELLA_ERR,  OUTPUT); digitalWrite(PIN_HUELLA_ERR,  LOW);
  pinMode(PIN_HUELLA_CRUZ, OUTPUT); digitalWrite(PIN_HUELLA_CRUZ, LOW);

  Serial.println(F("\n\n=== Boveda: modulo de HUELLA (Validacion Cruzada) ==="));
  mySerial.begin(57600, SERIAL_8N1, PIN_AS608_RX, PIN_AS608_TX);

  while (!finger.verifyPassword()) {
    Serial.println(F("ERROR: no se encuentra el AS608."));
    delay(2000);
  }
  Serial.println(F("Sensor AS608 detectado."));

  finger.getParameters();
  if (finger.capacity > 0) maxId = finger.capacity;
  finger.getTemplateCount();
  Serial.print(F("Huellas guardadas: ")); Serial.println(finger.templateCount);
  Serial.println(F("Envia 'r' para registrar una huella."));
}

// ===================== LOOP =====================
void loop() {
  static bool habPrev = false;

  revisarSerial();

  bool hab = habilitado();
  if (hab != habPrev) {
    habPrev = hab;
    if (hab) {
      uint8_t u = leerUsuarioEsperado();
      Serial.print(F("[FPGA] HAB_HUELLA=1 | Usuario esperado codigo: "));
      Serial.print(u);
      Serial.print(F(" (ID huella esperado: #"));
      Serial.print(obtenerIdHuellaEsperado(u));
      Serial.println(F(")"));
    } else {
      Serial.println(F("[FPGA] HAB_HUELLA=0 -> lector en REPOSO"));
    }
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
    Serial.println(F("Lectura ilegible -> ERROR ('E')"));
    enviarError(PIN_HUELLA_ERR);
    return;
  }

  p = finger.fingerSearch();
  if (p == FINGERPRINT_OK && finger.confidence >= MIN_CONFIANZA) {
    uint8_t userCode = leerUsuarioEsperado();
    uint16_t idEsperado = obtenerIdHuellaEsperado(userCode);

    if (idEsperado != 0 && finger.fingerID == idEsperado) {
      Serial.print(F("ACCESO CONCEDIDO | ID #")); Serial.print(finger.fingerID);
      Serial.print(F(" coincide con usuario codigo ")); Serial.println(userCode);
      pulso(PIN_HUELLA_OK);
      esperarSinDedoHab();
    } else {
      Serial.print(F("ERROR CRUZADO ('C') | Esperaba ID #")); Serial.print(idEsperado);
      Serial.print(F(" pero se puso ID #")); Serial.println(finger.fingerID);
      enviarError(PIN_HUELLA_CRUZ);
    }
  } else if (p == FINGERPRINT_OK || p == FINGERPRINT_NOTFOUND) {
    Serial.println(F("ACCESO DENEGADO -> ERROR GENERAL ('E')"));
    enviarError(PIN_HUELLA_ERR);
  } else {
    delay(100);
  }
}

void enviarError(uint8_t pinSalida) {
  uint32_t t0 = millis();
  pulso(pinSalida);

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
void limpiarSerial() { delay(50); while (Serial.available()) Serial.read(); }

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
  while (millis() - t0 < timeout) { if (finger.getImage() == FINGERPRINT_OK) return true; delay(20); }
  return false;
}

bool esperarSinDedo(uint32_t timeout) {
  uint32_t t0 = millis();
  while (millis() - t0 < timeout) { if (finger.getImage() == FINGERPRINT_NOFINGER) return true; delay(20); }
  return false;
}

void revisarSerial() {
  if (!Serial.available()) return;
  char c = Serial.read();
  if (c == 'r' || c == 'R') registrarHuella();
}

void registrarHuella() {
  Serial.println(F("\n=== MODO REGISTRO ==="));
  Serial.print(F("Escribe el ID (1 a ")); Serial.print(maxId); Serial.println(F(") y Enter:"));
  limpiarSerial();
  int id = leerLinea().toInt();
  if (id < 1 || id > (int)maxId) { Serial.println(F("ID invalido.")); return; }

  Serial.println(F("Pon el dedo..."));
  if (!esperarDedo(TIMEOUT_REGISTRO_MS))       { Serial.println(F("Tiempo agotado.")); return; }
  if (finger.image2Tz(1) != FINGERPRINT_OK)    { Serial.println(F("Error imagen 1.")); return; }

  Serial.println(F("Quita el dedo..."));
  delay(1000);
  if (!esperarSinDedo(TIMEOUT_REGISTRO_MS))    { Serial.println(F("Tiempo agotado.")); return; }

  Serial.println(F("Pon el MISMO dedo otra vez..."));
  if (!esperarDedo(TIMEOUT_REGISTRO_MS))       { Serial.println(F("Tiempo agotado.")); return; }
  if (finger.image2Tz(2) != FINGERPRINT_OK)    { Serial.println(F("Error imagen 2.")); return; }

  if (finger.createModel() != FINGERPRINT_OK)  { Serial.println(F("No coinciden.")); return; }
  if (finger.storeModel(id) != FINGERPRINT_OK) { Serial.println(F("Error al guardar.")); return; }

  Serial.print(F("EXITO: huella guardada en ID #")); Serial.println(id);
  esperarSinDedo(5000);
}
