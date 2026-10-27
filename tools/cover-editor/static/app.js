// Recadrage : glisser (ou cliquer) dans l'aperçu -> pourcentage X/Y -> object-position
// (même format que le site : "X% Y%"), avec un repère visuel qui suit le doigt/curseur.
const img = document.getElementById("previewImg");
const artBox = document.getElementById("artBox");
const marker = document.getElementById("posMarker");
const posField = document.getElementById("objectPositionField");
const posReadout = document.getElementById("posReadoutValue");
const urlField = document.getElementById("coverUrlField");
const linkStatus = document.getElementById("linkStatus");
const zoomSlider = document.getElementById("zoomSlider");
const zoomValue = document.getElementById("zoomValue");
const zoomField = document.getElementById("zoomField");

function currentZoom() {
  return zoomField ? parseFloat(zoomField.value) || 1 : 1;
}

function applyZoom(percent) {
  const z = Math.max(1, Math.min(3, percent / 100));
  if (img) img.style.transform = `scale(${z})`;
  if (zoomField) zoomField.value = z;
  if (zoomValue) zoomValue.textContent = `${Math.round(z * 100)}%`;
  if (zoomSlider) zoomSlider.value = Math.round(z * 100);
}

function parsePosition(pos) {
  const m = /(-?\d+(?:\.\d+)?)%\s+(-?\d+(?:\.\d+)?)%/.exec(pos || "");
  return m ? { x: parseFloat(m[1]), y: parseFloat(m[2]) } : { x: 50, y: 20 };
}

function applyPosition(x, y) {
  x = Math.max(0, Math.min(100, x));
  y = Math.max(0, Math.min(100, y));
  const pos = `${Math.round(x)}% ${Math.round(y)}%`;
  if (img) {
    img.style.objectPosition = pos;
    // Le zoom doit garder son origine sur le même point que le cadrage, sinon zoomer
    // fait "sauter" l'image ailleurs que le point choisi.
    img.style.transformOrigin = pos;
  }
  if (posField) posField.value = pos;
  if (posReadout) posReadout.textContent = pos;
  if (marker) {
    marker.style.left = `${x}%`;
    marker.style.top = `${y}%`;
  }
}

// Position initiale du repère au chargement.
if (posField) {
  const initial = parsePosition(posField.value);
  applyPosition(initial.x, initial.y);
}

function positionFromEvent(e) {
  const rect = artBox.getBoundingClientRect();
  const point = e.touches ? e.touches[0] : e;
  const x = ((point.clientX - rect.left) / rect.width) * 100;
  const y = ((point.clientY - rect.top) / rect.height) * 100;
  return { x, y };
}

let dragging = false;
if (artBox) {
  artBox.addEventListener("pointerdown", (e) => {
    dragging = true;
    const { x, y } = positionFromEvent(e);
    applyPosition(x, y);
  });
  artBox.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    const { x, y } = positionFromEvent(e);
    applyPosition(x, y);
  });
  window.addEventListener("pointerup", () => { dragging = false; });
}

const resetBtn = document.getElementById("resetPos");
if (resetBtn) {
  resetBtn.addEventListener("click", () => {
    applyPosition(50, 20);
    applyZoom(100);
  });
}

if (zoomSlider) {
  zoomSlider.addEventListener("input", () => applyZoom(parseFloat(zoomSlider.value)));
}

document.querySelectorAll(".thumb").forEach((btn) => {
  btn.addEventListener("click", () => {
    const url = btn.dataset.url;
    urlField.value = url;
    if (img) img.src = url;
    checkLink(url);
  });
});

// Vérification du lien collé : uniquement des schémas http/https, et une vraie image
// accessible (voir core/link_check.py côté serveur pour les garde-fous de sécurité).
let checkTimer = null;
function checkLink(url) {
  if (!linkStatus) return;
  const value = (url || "").trim();
  if (!value) {
    linkStatus.className = "linkStatus";
    linkStatus.textContent = "";
    return;
  }
  linkStatus.className = "linkStatus checking";
  linkStatus.textContent = "Vérification du lien…";
  fetch(`/api/check-image?url=${encodeURIComponent(value)}`)
    .then((r) => r.json())
    .then((data) => {
      if (data.ok) {
        linkStatus.className = "linkStatus ok";
        linkStatus.textContent = "Image valide et accessible.";
      } else {
        linkStatus.className = "linkStatus bad";
        linkStatus.textContent = `Problème avec ce lien : ${data.reason}.`;
      }
    })
    .catch(() => {
      linkStatus.className = "linkStatus bad";
      linkStatus.textContent = "Vérification impossible (hors-ligne ?).";
    });
}

if (urlField) {
  urlField.addEventListener("input", () => {
    clearTimeout(checkTimer);
    checkTimer = setTimeout(() => checkLink(urlField.value), 500);
  });
  if (urlField.value.trim()) checkLink(urlField.value);
}

// Recherche par titre (respecte le filtre de plateforme courant), liste déroulante.
const searchBox = document.getElementById("searchBox");
const searchResults = document.getElementById("searchResults");
let searchTimer = null;

if (searchBox) {
  searchBox.addEventListener("input", () => {
    clearTimeout(searchTimer);
    const q = searchBox.value.trim();
    if (!q) {
      searchResults.hidden = true;
      searchResults.innerHTML = "";
      return;
    }
    searchTimer = setTimeout(async () => {
      const platform = searchBox.dataset.platform || "";
      const res = await fetch(`/api/search?q=${encodeURIComponent(q)}&platform=${encodeURIComponent(platform)}`);
      const games = await res.json();
      const suffix = platform ? `&platform=${encodeURIComponent(platform)}` : "";
      searchResults.innerHTML = games
        .map((g) => `<a href="/?id=${encodeURIComponent(g.id)}${suffix}">${g.title}${g.year ? ` (${g.year})` : ""}</a>`)
        .join("");
      searchResults.hidden = games.length === 0;
    }, 200);
  });

  document.addEventListener("click", (e) => {
    if (e.target !== searchBox) searchResults.hidden = true;
  });
}
