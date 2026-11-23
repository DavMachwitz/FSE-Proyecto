const video = document.getElementById('videoInput');
const canvas = document.getElementById('overlayCanvas');
const statusBox = document.getElementById('status-box');
const tituloFase = document.getElementById('titulo-fase');
const btnConectarSerial = document.getElementById('btnConectarSerial');
const btnSimularHuella = document.getElementById('btnSimularHuella');
const btnReiniciarSistema = document.getElementById('btnReiniciarSistema');

// Configuración

const INTEGRANTES = ['david', 'santiago', 'abner'];
const RUTA_MODELOS = './models';
const RUTA_FOTOS = './registros';
const UMBRAL_DISTANCIA = 0.50;
const WS_URL = 'ws://127.0.0.1:8765'; // Puente USB-Serial en Termux (9600 bps)

// Temporizaciones (en milisegundos)
const TIEMPO_ROSTRO_ESTATICO_MS = 2000; // 2 s continuos firme frente a cámara
const TIEMPO_PAUSA_ERROR_MS = 3000;     // 3 s mostrando claramente el error en pantalla
const TIMEOUT_ERROR_FACIAL_MS = 30000;  // 30 s sin presencia para limpiar contador de fallos
const TIMEOUT_VOZ_MS = 60000;           // 60 s para dictar palabra clave (TO=1)
const TIMEOUT_HUELLA_MS = 60000;        // 60 s esperando huella en AS608 (TO=1)
const TIEMPO_BLOQUEO_MS = 60000;        // 60 s de penalización por 3 fallos (S4)

// Variables de estado del sistema
let labeledFaceDescriptors = null;
let globalFaceMatcher = null;
let globalDisplaySize = null;
let intervalDeteccion = null;

// Estados HMI: 'ESPERA_ROSTRO' | 'PAUSA_ERROR' | 'APROBADO' | 'FASE_VOZ' | 'FASE_HUELLA' | 'BOVEDA_ABIERTA' | 'BLOQUEADO'
let estadoActual = 'ESPERA_ROSTRO';
let tiempoPrimerAvistamiento = null;
let temporizadorInactividad = null;
let temporizadorPausaError = null;
let temporizadorVoz = null;
let temporizadorHuella = null;
let temporizadorBloqueo = null;
let recognitionInstance = null;

// Contador de seguridad
let contadorFallos = 0;
const MAX_FALLOS = 3;

// Conexión WebSocket hacia el puente Python en Termux
let wsSerial = null;

// =========================================================================
// 1. INICIALIZACIÓN DE MODELOS Y CÁMARA
// =========================================================================
async function inicializar() {
  conectarPuenteUSB();

  try {
    actualizarInterfaz('Cargando modelos de IA...', '#333');
    await Promise.all([
      faceapi.nets.ssdMobilenetv1.loadFromUri(RUTA_MODELOS),
      faceapi.nets.faceLandmark68Net.loadFromUri(RUTA_MODELOS),
      faceapi.nets.faceRecognitionNet.loadFromUri(RUTA_MODELOS)
    ]);

    actualizarInterfaz('Cargando credenciales autorizadas...', '#333');
    labeledFaceDescriptors = await cargarRostrosAutorizados();

    actualizarInterfaz('Iniciando sensor de video...', '#333');
    await iniciarCamara();
  } catch (err) {
    console.error(err);
    actualizarInterfaz(`Fallo de inicio: ${err.message}`, '#8b0000');
  }
}

async function cargarRostrosAutorizados() {
  return Promise.all(
    INTEGRANTES.map(async (nombre) => {
      const img = await faceapi.fetchImage(`${RUTA_FOTOS}/${nombre}.jpg`);
      const det = await faceapi.detectSingleFace(img).withFaceLandmarks().withFaceDescriptor();
      if (!det) throw new Error(`Sin rostro claro en ${nombre}.jpg`);
      return new faceapi.LabeledFaceDescriptors(nombre, [det.descriptor]);
    })
  );
}

async function iniciarCamara() {
  // Solicita permiso inicial para poder listar etiquetas de cámaras disponibles
  let tempStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false });
  const dispositivos = await navigator.mediaDevices.enumerateDevices();
  const camaras = dispositivos.filter((d) => d.kind === 'videoinput');

  // Busca si hay webcam externa USB (HP) conectada al hub; si no, usa la frontal
  const camaraExterna = camaras.find((c) => /usb|hp|external|uvc/i.test(c.label));

  if (camaraExterna) {
    tempStream.getTracks().forEach((t) => t.stop());
    const streamUSB = await navigator.mediaDevices.getUserMedia({
      video: {
        deviceId: { exact: camaraExterna.deviceId },
        width: { ideal: 640 },
        height: { ideal: 480 }
      },
      audio: false
    });
    video.srcObject = streamUSB;
    console.log('[CÁMARA] Usando webcam externa:', camaraExterna.label);
  } else {
    video.srcObject = tempStream;
    console.log('[CÁMARA] Usando cámara integrada de la tablet.');
  }
}

video.addEventListener('play', () => {
  globalDisplaySize = { width: video.clientWidth || 640, height: video.clientHeight || 480 };
  faceapi.matchDimensions(canvas, globalDisplaySize);
  globalFaceMatcher = new faceapi.FaceMatcher(labeledFaceDescriptors, UMBRAL_DISTANCIA);

  iniciarEscaneoFacial();
});

// =========================================================================
// 2. FASE 1: RECONOCIMIENTO FACIAL (S0)
// =========================================================================
function iniciarEscaneoFacial() {
  limpiarTodosLosTemporizadores();
  estadoActual = 'ESPERA_ROSTRO';
  tiempoPrimerAvistamiento = null;
  btnSimularHuella.disabled = true;

  tituloFase.innerText = 'FASE 1: RECONOCIMIENTO FACIAL';
  actualizarInterfaz('SISTEMA ACTIVO: Mire a la cámara para autenticar', '#1a365d');

  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, canvas.width, canvas.height);

  if (intervalDeteccion) clearInterval(intervalDeteccion);

  intervalDeteccion = setInterval(async () => {
    if (estadoActual !== 'ESPERA_ROSTRO') return;

    const detections = await faceapi
      .detectAllFaces(video, new faceapi.SsdMobilenetv1Options({ minConfidence: 0.5 }))
      .withFaceLandmarks()
      .withFaceDescriptors();

    if (estadoActual !== 'ESPERA_ROSTRO') return;

    ctx.clearRect(0, 0, canvas.width, canvas.height);

    if (detections.length === 0) {
      tiempoPrimerAvistamiento = null;
      return;
    }

    if (!tiempoPrimerAvistamiento) {
      tiempoPrimerAvistamiento = Date.now();
    }

    const resized = faceapi.resizeResults(detections, globalDisplaySize);
    const primary = resized[0];
    const match = globalFaceMatcher.findBestMatch(primary.descriptor);
    const box = primary.detection.box;

    const tiempoSostenido = Date.now() - tiempoPrimerAvistamiento;

    // FASE A: ROSTRO EN ANÁLISIS / DE PASO (AMARILLO)
    if (tiempoSostenido < TIEMPO_ROSTRO_ESTATICO_MS) {
      dibujarRecuadro(ctx, box, '#ecc94b', 'Identificando... Quédese quieto');
      actualizarInterfaz('Rostro detectado. Manténgase firme...', '#744210');
      return;
    }

    // FASE B: VEREDICTO TRAS CUMPLIR EL TIEMPO ESTÁTICO
    if (match.label !== 'unknown') {
      estadoActual = 'APROBADO';
      clearInterval(intervalDeteccion);
      intervalDeteccion = null;
      contadorFallos = 0;
      limpiarTimeoutReinicio();

      dibujarRecuadro(ctx, box, '#38a169', `✔ AUTORIZADO: ${match.label.toUpperCase()}`);
      actualizarInterfaz(`✔ IDENTIDAD CONFIRMADA: ${match.label.toUpperCase()}`, '#22543d');
      enviarComandoSerial('F');

      setTimeout(() => {
        ctx.clearRect(0, 0, canvas.width, canvas.height);
        iniciarFaseVoz();
      }, 900);
    } else {
      tiempoPrimerAvistamiento = null;
      contadorFallos++;
      enviarComandoSerial('E');

      if (contadorFallos >= MAX_FALLOS) {
        activarBloqueoSeguridad();
      } else {
        mostrarErrorFacialTemporal(ctx, box);
      }
    }
  }, 200);
}

function mostrarErrorFacialTemporal(ctx, lastBox) {
  estadoActual = 'PAUSA_ERROR';
  let segs = Math.ceil(TIEMPO_PAUSA_ERROR_MS / 1000);

  const renderAviso = () => {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    if (lastBox) {
      dibujarRecuadro(ctx, lastBox, '#e53e3e', `✖ ACCESO DENEGADO (${contadorFallos}/${MAX_FALLOS})`);
    }
    actualizarInterfaz(
      `✖ ROSTRO NO RECONOCIDO — Intento ${contadorFallos} de ${MAX_FALLOS} (Reintentando en ${segs}s...)`,
      '#9b2c2c'
    );
  };

  renderAviso();

  temporizadorPausaError = setInterval(() => {
    segs--;
    if (segs > 0) {
      renderAviso();
    } else {
      clearInterval(temporizadorPausaError);
      temporizadorPausaError = null;
      ctx.clearRect(0, 0, canvas.width, canvas.height);

      if (estadoActual === 'PAUSA_ERROR') {
        estadoActual = 'ESPERA_ROSTRO';
        actualizarInterfaz(`SISTEMA ACTIVO: Mire a la cámara (Fallos acumulados: ${contadorFallos}/${MAX_FALLOS})`, '#1a365d');
        iniciarTimeoutReinicio(TIMEOUT_ERROR_FACIAL_MS);
      }
    }
  }, 1000);
}

// =========================================================================
// 3. PROTOCOLO DE BLOQUEO POR 3 FALLOS (S4 - LOCKDOWN 60s)
// =========================================================================
function activarBloqueoSeguridad() {
  limpiarTodosLosTemporizadores();
  estadoActual = 'BLOQUEADO';
  btnSimularHuella.disabled = true;

  if (intervalDeteccion) {
    clearInterval(intervalDeteccion);
    intervalDeteccion = null;
  }

  const ctx = canvas.getContext('2d');
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  setTimeout(() => ctx.clearRect(0, 0, canvas.width, canvas.height), 250);

  enviarComandoSerial('B');
  let segundosRestantes = TIEMPO_BLOQUEO_MS / 1000;

  tituloFase.innerText = 'ALERTA DE SEGURIDAD — SISTEMA BLOQUEADO';
  actualizarInterfaz(`¡SISTEMA BLOQUEADO POR SEGURIDAD! Espere: ${segundosRestantes}s`, '#4a0e0e');

  temporizadorBloqueo = setInterval(() => {
    segundosRestantes--;
    actualizarInterfaz(`¡SISTEMA BLOQUEADO POR SEGURIDAD! Espere: ${segundosRestantes}s`, '#4a0e0e');

    if (segundosRestantes <= 0) {
      clearInterval(temporizadorBloqueo);
      temporizadorBloqueo = null;
      contadorFallos = 0;
      iniciarEscaneoFacial();
    }
  }, 1000);
}

// =========================================================================
// 4. FASE 2: RECONOCIMIENTO DE VOZ (S1)
// =========================================================================
function iniciarFaseVoz() {
  estadoActual = 'FASE_VOZ';
  tituloFase.innerText = 'FASE 2: AUTENTICACIÓN POR VOZ';
  actualizarInterfaz('FASE 2: Diga la palabra clave "Abrir bóveda" (60s)', '#2b6cb0');

  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) {
    actualizarInterfaz('Navegador sin soporte de voz nativo', '#742a2a');
    return;
  }

  recognitionInstance = new SpeechRecognition();
  recognitionInstance.lang = 'es-MX';
  recognitionInstance.continuous = false;
  recognitionInstance.interimResults = false;

  temporizadorVoz = setTimeout(() => {
    enviarComandoSerial('T');
    abortarFaseVoz('Tiempo agotado en fase de voz (60s). Reiniciando...');
  }, TIMEOUT_VOZ_MS);

  recognitionInstance.onresult = (event) => {
    const audioTexto = event.results[0][0].transcript.toLowerCase().trim();
    console.log('[Voz recibida]:', audioTexto);

    if (audioTexto.includes('abrir') && (audioTexto.includes('boveda') || audioTexto.includes('bóveda'))) {
      clearTimeout(temporizadorVoz);
      temporizadorVoz = null;
      recognitionInstance = null;

      enviarComandoSerial('V');
      iniciarFaseHuella(audioTexto);
    } else {
      contadorFallos++;
      enviarComandoSerial('E');

      if (contadorFallos >= MAX_FALLOS) {
        if (recognitionInstance) {
          try { recognitionInstance.stop(); } catch (_) {}
          recognitionInstance = null;
        }
        activarBloqueoSeguridad();
      } else {
        actualizarInterfaz(
          `✖ Clave incorrecta: "${audioTexto}" (${contadorFallos}/${MAX_FALLOS}). Intente de nuevo...`,
          '#9b2c2c'
        );
        setTimeout(() => {
          if (estadoActual === 'FASE_VOZ') {
            actualizarInterfaz('FASE 2: Diga la palabra clave "Abrir bóveda"', '#2b6cb0');
            try { recognitionInstance.start(); } catch (_) {}
          }
        }, 2000);
      }
    }
  };

  recognitionInstance.onerror = (e) => {
    if (estadoActual === 'FASE_VOZ' && e.error !== 'aborted') {
      try { recognitionInstance.start(); } catch (_) {}
    }
  };

  try { recognitionInstance.start(); } catch (_) {}
}

function abortarFaseVoz(mensaje) {
  if (recognitionInstance) {
    try { recognitionInstance.stop(); } catch (_) {}
    recognitionInstance = null;
  }
  clearTimeout(temporizadorVoz);
  temporizadorVoz = null;
  contadorFallos = 0;
  actualizarInterfaz(mensaje, '#742a2a');

  setTimeout(() => {
    iniciarEscaneoFacial();
  }, 2500);
}

// =========================================================================
// 5. FASE 3: HUELLA DIGITAL AS608 (S2) Y APERTURA (S3)
// =========================================================================
function iniciarFaseHuella(fraseValidada) {
  estadoActual = 'FASE_HUELLA';
  btnSimularHuella.disabled = false;

  tituloFase.innerText = 'FASE 3: VERIFICACIÓN DE HUELLA DIGITAL';
  actualizarInterfaz(
    `✔ CLAVE "${fraseValidada.toUpperCase()}" ACEPTADA — Coloque su dedo en el sensor AS608`,
    '#2c5282'
  );

  temporizadorHuella = setTimeout(() => {
    btnSimularHuella.disabled = true;
    contadorFallos = 0;
    actualizarInterfaz('Tiempo agotado en sensor de huella. Reiniciando...', '#742a2a');
    setTimeout(() => iniciarEscaneoFacial(), 2000);
  }, TIMEOUT_HUELLA_MS);
}

function manejarBovedaAbierta() {
  if (temporizadorHuella) {
    clearTimeout(temporizadorHuella);
    temporizadorHuella = null;
  }
  estadoActual = 'BOVEDA_ABIERTA';
  btnSimularHuella.disabled = true;
  contadorFallos = 0;

  tituloFase.innerText = 'ACCESO CONCEDIDO — BÓVEDA ABIERTA';
  actualizarInterfaz('✔ HUELLA VERIFICADA — BÓVEDA ABIERTA (Esperando cierre de compuerta...)', '#22543d');
}

function manejarCierrePuerta() {
  tituloFase.innerText = 'BÓVEDA CERRADA';
  actualizarInterfaz('Compuerta cerrada. Restableciendo sistema de seguridad...', '#1a365d');
  setTimeout(() => {
    iniciarEscaneoFacial();
  }, 1500);
}

// =========================================================================
// 6. PUENTE WEBSOCKET <-> CABLE USB OTG (TERMUX @ 9600 BAUDIOS)
// =========================================================================
function conectarPuenteUSB() {
  if (wsSerial && (wsSerial.readyState === WebSocket.OPEN || wsSerial.readyState === WebSocket.CONNECTING)) {
    return;
  }

  wsSerial = new WebSocket(WS_URL);

  wsSerial.onopen = () => {
    console.log('[USB-BRIDGE] Conectado al puente serial de Termux.');
    btnConectarSerial.innerText = '✔ Cable USB Conectado (9600 bps)';
    btnConectarSerial.classList.add('conectado');
  };

  wsSerial.onmessage = (event) => {
    const datos = String(event.data);
    for (const char of datos) {
      procesarDatoEntrante(char);
    }
  };

  wsSerial.onclose = () => {
    btnConectarSerial.innerText = 'Reconectar Cable USB (OTG)';
    btnConectarSerial.classList.remove('conectado');
    setTimeout(conectarPuenteUSB, 3000);
  };

  wsSerial.onerror = (err) => {
    console.warn('[USB-BRIDGE] Esperando puente Python en Termux...', err);
  };
}

function procesarDatoEntrante(char) {
  console.log(`[ENTRADA CABLE USB]: '${char}'`);

  switch (char) {
    case 'H':
      if (estadoActual === 'FASE_HUELLA') {
        manejarBovedaAbierta();
      }
      break;

    case 'E':
      if (estadoActual === 'FASE_HUELLA') {
        contadorFallos++;
        if (contadorFallos >= MAX_FALLOS) {
          activarBloqueoSeguridad();
        } else {
          actualizarInterfaz(
            `✖ HUELLA NO RECONOCIDA (${contadorFallos}/${MAX_FALLOS}). Intente nuevamente...`,
            '#9b2c2c'
          );
        }
      }
      break;

    case 'C':
      if (estadoActual === 'BOVEDA_ABIERTA') {
        manejarCierrePuerta();
      }
      break;

    case 'B':
      if (estadoActual !== 'BLOQUEADO') {
        activarBloqueoSeguridad();
      }
      break;
  }
}

function enviarComandoSerial(caracter) {
  console.log(`[SALIDA CABLE USB -> ESP32/FPGA]: '${caracter}'`);
  if (wsSerial && wsSerial.readyState === WebSocket.OPEN) {
    wsSerial.send(caracter);
  }
}

// =========================================================================
// 7. EVENTOS DE BOTONES Y UTILIDADES
// =========================================================================
btnConectarSerial.addEventListener('click', conectarPuenteUSB);

btnSimularHuella.addEventListener('click', () => {
  if (estadoActual === 'FASE_HUELLA') {
    enviarComandoSerial('H');
    manejarBovedaAbierta();
  }
});

btnReiniciarSistema.addEventListener('click', () => {
  if (recognitionInstance) {
    try { recognitionInstance.stop(); } catch (_) {}
    recognitionInstance = null;
  }
  contadorFallos = 0;
  enviarComandoSerial('R');
  iniciarEscaneoFacial();
});

function iniciarTimeoutReinicio(ms) {
  limpiarTimeoutReinicio();
  temporizadorInactividad = setTimeout(() => {
    contadorFallos = 0;
    actualizarInterfaz('SISTEMA ACTIVO: Mire a la cámara para autenticar', '#1a365d');
    const ctx = canvas.getContext('2d');
    ctx.clearRect(0, 0, canvas.width, canvas.height);
  }, ms);
}

function limpiarTimeoutReinicio() {
  if (temporizadorInactividad) {
    clearTimeout(temporizadorInactividad);
    temporizadorInactividad = null;
  }
}

function limpiarTodosLosTemporizadores() {
  limpiarTimeoutReinicio();
  if (temporizadorPausaError) { clearInterval(temporizadorPausaError); temporizadorPausaError = null; }
  if (temporizadorVoz) { clearTimeout(temporizadorVoz); temporizadorVoz = null; }
  if (temporizadorHuella) { clearTimeout(temporizadorHuella); temporizadorHuella = null; }
  if (temporizadorBloqueo) { clearInterval(temporizadorBloqueo); temporizadorBloqueo = null; }
}

function dibujarRecuadro(ctx, box, color, etiqueta) {
  ctx.strokeStyle = color;
  ctx.lineWidth = 4;
  ctx.strokeRect(box.x, box.y, box.width, box.height);

  ctx.fillStyle = color;
  ctx.font = 'bold 15px Arial';
  const textoAncho = ctx.measureText(etiqueta).width;
  ctx.fillRect(box.x, box.y - 25, textoAncho + 12, 25);

  ctx.fillStyle = '#ffffff';
  ctx.fillText(etiqueta, box.x + 6, box.y - 7);
}

function actualizarInterfaz(texto, colorFondo) {
  statusBox.innerText = texto;
  if (colorFondo) statusBox.style.backgroundColor = colorFondo;
}

window.onload = inicializar;