const canvas = document.querySelector("#display");
const context = canvas.getContext("2d", { alpha: false });
const signal = document.querySelector("#signal");
const connectionText = document.querySelector("#connectionText");
const frameState = document.querySelector("#frameState");
const frameAge = document.querySelector("#frameAge");
const statusText = document.querySelector("#statusText");
const armButton = document.querySelector("#armButton");
const armHint = document.querySelector("#armHint");
const armDialog = document.querySelector("#armDialog");
const touchMark = document.querySelector("#touchMark");
const intervalSelect = document.querySelector("#interval");

let token = "";
let screen = { width: 1404, height: 1872 };
let rotation = [0, 90, 180, 270].includes(Number(localStorage.getItem("paper-remote-rotation")))
  ? Number(localStorage.getItem("paper-remote-rotation")) : 180;
let armedUntil = 0;
let frameTimestamp = 0;
let refreshTimer;
let loading = false;
let refreshRequested = false;
let pointerStart;

async function api(path, options = {}) {
  const headers = new Headers(options.headers);
  if (token) headers.set("x-paper-remote-token", token);
  if (options.body) headers.set("content-type", "application/json");
  const response = await fetch(path, { ...options, headers, cache: "no-store" });
  if (!response.ok) {
    let message = `Request failed (${response.status})`;
    try { message = (await response.json()).error ?? message; } catch {}
    throw new Error(message);
  }
  return response;
}

function setConnection(mode, text) {
  signal.className = `signal ${mode}`;
  connectionText.textContent = text;
}

function renderArmState() {
  const armed = Date.now() < armedUntil;
  armButton.classList.toggle("armed", armed);
  armButton.innerHTML = armed ? "<span>●</span> Input armed" : "<span>○</span> Disarmed";
  armHint.textContent = armed ? `Auto-disarms in ${Math.max(1, Math.ceil((armedUntil - Date.now()) / 60000))} min.` : "Unlock the tablet physically before arming.";
}

function drawImage(image) {
  const quarter = ((rotation % 360) + 360) % 360;
  if (quarter === 90 || quarter === 270) {
    canvas.width = screen.height;
    canvas.height = screen.width;
  } else {
    canvas.width = screen.width;
    canvas.height = screen.height;
  }
  context.save();
  if (quarter === 90) { context.translate(canvas.width, 0); context.rotate(Math.PI / 2); }
  if (quarter === 180) { context.translate(canvas.width, canvas.height); context.rotate(Math.PI); }
  if (quarter === 270) { context.translate(0, canvas.height); context.rotate(-Math.PI / 2); }
  context.drawImage(image, 0, 0, screen.width, screen.height);
  context.restore();
}

async function loadFrame(immediate = false) {
  clearTimeout(refreshTimer);
  if (loading) {
    if (immediate) refreshRequested = true;
    return;
  }
  loading = true;
  frameState.textContent = immediate ? "Refreshing…" : "Reading tablet…";
  try {
    const response = await api(`/api/frame?t=${Date.now()}`);
    const blob = await response.blob();
    const image = await createImageBitmap(blob);
    drawImage(image);
    image.close();
    frameTimestamp = Date.now();
    frameState.textContent = `Live · ${rotation}°`;
    setConnection("live", "SSH connected");
    statusText.textContent = "Frame received; display ready";
  } catch (error) {
    setConnection("error", "Capture error");
    frameState.textContent = "Capture unavailable";
    statusText.textContent = error.message;
  } finally {
    loading = false;
    if (refreshRequested) {
      refreshRequested = false;
      queueMicrotask(() => loadFrame(true));
    } else {
      refreshTimer = setTimeout(loadFrame, Number(intervalSelect.value));
    }
  }
}

function canvasPoint(event) {
  const bounds = canvas.getBoundingClientRect();
  return {
    x: Math.max(0, Math.min(canvas.width - 1, Math.round((event.clientX - bounds.left) * canvas.width / bounds.width))),
    y: Math.max(0, Math.min(canvas.height - 1, Math.round((event.clientY - bounds.top) * canvas.height / bounds.height))),
  };
}

function rawPoint(point) {
  if (rotation === 90) return { x: point.y, y: screen.height - 1 - point.x };
  if (rotation === 180) return { x: screen.width - 1 - point.x, y: screen.height - 1 - point.y };
  if (rotation === 270) return { x: screen.width - 1 - point.y, y: point.x };
  return point;
}

function flashTouch(event) {
  const shell = document.querySelector(".display-shell").getBoundingClientRect();
  touchMark.style.left = `${event.clientX - shell.left}px`;
  touchMark.style.top = `${event.clientY - shell.top}px`;
  touchMark.classList.remove("show");
  requestAnimationFrame(() => touchMark.classList.add("show"));
}

async function sendInput(body) {
  if (Date.now() >= armedUntil) { armedUntil = 0; renderArmState(); armDialog.showModal(); return; }
  armButton.classList.add("busy");
  statusText.textContent = body.action === "tap" ? "Sending tap…" : "Sending swipe…";
  try {
    const response = await api("/api/input", { method: "POST", body: JSON.stringify(body) });
    const result = await response.json();
    armedUntil = result.armed_until;
    statusText.textContent = "Input delivered; refreshing display";
    setTimeout(() => loadFrame(true), 75);
  } catch (error) {
    statusText.textContent = error.message;
    if (error.message.includes("disarmed")) armedUntil = 0;
  } finally {
    armButton.classList.remove("busy");
    renderArmState();
  }
}

canvas.addEventListener("pointerdown", event => {
  if (event.button !== 0) return;
  canvas.setPointerCapture(event.pointerId);
  pointerStart = { point: canvasPoint(event), time: performance.now(), event };
});
canvas.addEventListener("pointerup", event => {
  if (!pointerStart) return;
  const end = canvasPoint(event);
  const start = pointerStart;
  pointerStart = undefined;
  flashTouch(event);
  const distance = Math.hypot(end.x - start.point.x, end.y - start.point.y);
  const first = rawPoint(start.point);
  const last = rawPoint(end);
  if (distance < Math.max(canvas.width, canvas.height) * .018) {
    void sendInput({ action: "tap", x: first.x, y: first.y });
  } else {
    const duration = Math.max(100, Math.min(5000, Math.round(performance.now() - start.time)));
    void sendInput({ action: "swipe", x1: first.x, y1: first.y, x2: last.x, y2: last.y, duration_ms: duration });
  }
});
canvas.addEventListener("pointercancel", () => { pointerStart = undefined; });

armButton.addEventListener("click", async () => {
  if (Date.now() < armedUntil) {
    const response = await api("/api/disarm", { method: "POST", body: "{}" });
    armedUntil = (await response.json()).armed_until;
    renderArmState();
  } else armDialog.showModal();
});
armDialog.addEventListener("close", async () => {
  if (armDialog.returnValue !== "confirm") return;
  try {
    const response = await api("/api/arm", { method: "POST", body: JSON.stringify({ confirmed_unlocked: true }) });
    armedUntil = (await response.json()).armed_until;
    renderArmState();
    statusText.textContent = "Input armed for this local session";
  } catch (error) { statusText.textContent = error.message; }
});
document.querySelector("#rotateButton").addEventListener("click", () => {
  rotation = (rotation + 90) % 360;
  localStorage.setItem("paper-remote-rotation", String(rotation));
  void loadFrame(true);
});
document.querySelector("#refreshButton").addEventListener("click", () => loadFrame(true));
intervalSelect.addEventListener("change", () => loadFrame(true));
document.querySelectorAll("[data-control]").forEach(button => button.addEventListener("click", async () => {
  const action = button.dataset.control;
  button.disabled = true;
  statusText.textContent = `${action === "exit" ? "Exiting" : `Opening ${action}`}…`;
  try {
    const response = await api("/api/control", { method: "POST", body: JSON.stringify({ action }) });
    const result = await response.json();
    armedUntil = result.armed_until;
    renderArmState();
    setTimeout(() => loadFrame(true), 900);
  } catch (error) { statusText.textContent = error.message; }
  finally { button.disabled = false; }
}));

setInterval(() => {
  renderArmState();
  frameAge.textContent = frameTimestamp ? `${Math.max(0, Math.round((Date.now() - frameTimestamp) / 1000))}s` : "—";
}, 1000);

try {
  const session = await (await fetch("/api/session", { cache: "no-store" })).json();
  token = session.token;
  armedUntil = session.armed_until;
  screen = session.screen;
  renderArmState();
  await loadFrame(true);
} catch (error) {
  setConnection("error", "Local server unavailable");
  statusText.textContent = error.message;
}
