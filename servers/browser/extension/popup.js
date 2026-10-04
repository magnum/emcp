const state = document.querySelector("#state");
const payload = document.querySelector("#payload");
const error = document.querySelector("#error");
const camera = document.querySelector("#camera");
let stream = null;
let scanTimer = null;

refresh();
setInterval(refresh, 2000);

document.querySelector("#connect").addEventListener("click", async () => {
  error.textContent = "";
  try {
    const config = JSON.parse(payload.value);
    if (!config.ws || !config.token || !config.instance_id) throw new Error("Payload needs ws, token, and instance_id");
    await requestOrigins(config.origins || []);
    const response = await chrome.runtime.sendMessage({ kind: "connect", config });
    if (!response?.ok) throw new Error(response?.error || "connect failed");
    stopCamera();
    refresh();
  } catch (failure) {
    error.textContent = failure.message;
  }
});

document.querySelector("#disconnect").addEventListener("click", async () => {
  stopCamera();
  await chrome.runtime.sendMessage({ kind: "disconnect" });
  payload.value = "";
  refresh();
});

document.querySelector("#scan").addEventListener("click", scan);

async function refresh() {
  const status = await chrome.runtime.sendMessage({ kind: "status" });
  if (status?.superseded) {
    state.className = "offline";
    state.textContent = "Another Chrome window took this pairing";
    return;
  }
  if (status?.online) {
    state.className = "online";
    state.textContent = "Online";
  } else if (status?.paired) {
    state.className = "offline";
    state.textContent = "Paired, reconnecting";
  } else {
    state.className = "offline";
    state.textContent = "Not paired";
  }
}

async function requestOrigins(origins) {
  const patterns = (origins?.length ? origins : ["https://*/*"]).flatMap((entry) => {
    let value = String(entry).trim();
    if (!value) return [];
    if (!value.includes("://")) value = `*://${value}/*`;
    const rest = value.slice(value.indexOf("://") + 3);
    if (!rest.includes("/")) value = `${value.replace(/\/$/, "")}/*`;
    if (value.startsWith("*://")) {
      const tail = value.slice(4);
      return [`http://${tail}`, `https://${tail}`];
    }
    return [value];
  });
  const unique = [...new Set(patterns)];
  if (!unique.length || !chrome.permissions?.request) return;
  const granted = await chrome.permissions.request({ origins: unique });
  if (!granted) throw new Error("Host permission was not granted");
}

async function scan() {
  error.textContent = "";
  if (!("BarcodeDetector" in window)) {
    error.textContent = "This Chrome build cannot scan QR codes. Paste the payload instead.";
    return;
  }
  stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" } });
  camera.srcObject = stream;
  camera.hidden = false;
  const detector = new BarcodeDetector({ formats: ["qr_code"] });
  scanTimer = setInterval(async () => {
    const codes = await detector.detect(camera);
    if (!codes.length) return;
    payload.value = codes[0].rawValue;
    stopCamera();
  }, 400);
}

function stopCamera() {
  clearInterval(scanTimer);
  stream?.getTracks().forEach((track) => track.stop());
  stream = null;
  camera.hidden = true;
}
