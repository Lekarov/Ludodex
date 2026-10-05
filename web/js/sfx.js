// Bruitages de l'ouverture de booster : sons synthétisés au clavier Web Audio (aucun fichier
// audio à charger), repris tels quels de js/catalogue/sfx.js (moteur hors ligne) — juste sans la
// dépendance à `state.set.sound/vol` (réglage qui n'existe pas côté appli connectée). Volume fixe
// raisonnable ; pas de coupure pour l'instant (aucune page de réglages son sur Ludodex Online).
// Volume gardé sur cet appareil (localStorage), réglable depuis settings.html — 0..1, 0.7 par
// défaut. sfx.setVolume()/getVolume() sont utilisés par settings.js ; les sons eux-mêmes relisent
// getVolume() à chaque déclenchement (pas de cache) pour suivre un changement fait dans un autre
// onglet sans recharger la page.
const SFX_VOL_KEY = "ludodex_sfx_vol";
const sfx = (() => {
  let ctx = null;
  function getVolume(){
    const raw = localStorage.getItem(SFX_VOL_KEY);
    const v = raw === null ? 0.7 : parseFloat(raw);
    return Number.isFinite(v) ? Math.min(1, Math.max(0, v)) : 0.7;
  }
  function setVolume(v){
    localStorage.setItem(SFX_VOL_KEY, String(Math.min(1, Math.max(0, v))));
  }
  function ac(){
    if (!ctx){ const C = window.AudioContext || window.webkitAudioContext; if (!C) return null; ctx = new C(); }
    if (ctx.state === "suspended") ctx.resume();
    return ctx;
  }
  function tone(freq, start, dur, type = "sine", gain = 0.3, slideTo){
    const c = ac(); if (!c) return;
    const vol = getVolume(); if (vol <= 0) return;
    const t = c.currentTime + start, o = c.createOscillator(), g = c.createGain();
    o.type = type; o.frequency.setValueAtTime(freq, t);
    if (slideTo) o.frequency.exponentialRampToValueAtTime(slideTo, t + dur);
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain * vol, t + 0.01);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    o.connect(g).connect(c.destination); o.start(t); o.stop(t + dur + 0.02);
  }
  function noise(start, dur, gain = 0.25, freq = 2500){
    const c = ac(); if (!c) return;
    const vol = getVolume(); if (vol <= 0) return;
    const t = c.currentTime + start, len = Math.floor(c.sampleRate * dur), buf = c.createBuffer(1, len, c.sampleRate), d = buf.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = (Math.random() * 2 - 1) * (1 - i / len);
    const s = c.createBufferSource(), f = c.createBiquadFilter(), g = c.createGain();
    s.buffer = buf; f.type = "bandpass"; f.frequency.value = freq; f.Q.value = 0.8;
    g.gain.value = gain * vol;
    s.connect(f).connect(g).connect(c.destination); s.start(t);
  }
  return {
    unlock(){ ac(); },
    getVolume, setVolume,
    press(){ noise(0, 0.05, 0.22, 550); tone(140, 0, 0.06, "sine", 0.12); }, // carton compressé au clic sur le paquet
    tear(){ noise(0, 0.18, 0.18, 1800); noise(0.2, 0.15, 0.2, 2400); noise(0.4, 0.12, 0.22, 3000); noise(0.62, 0.3, 0.35, 1500); },
    flip(){ noise(0, 0.08, 0.16, 3400); noise(0.05, 0.1, 0.14, 1900); tone(200, 0.1, 0.06, "sine", 0.09); }, // carte qui se retourne
    card(r){ tone(420 * Math.pow(1.15, r), 0, 0.09, "triangle", 0.22); },
    chime(r){ const b = [0, 0, 0, 660, 784, 880][r]; [1, 1.25, 1.5, 2].slice(0, r - 1).forEach((m, i) => tone(b * m, 0.45 + i * 0.09, 0.5, "sine", 0.18)); },
    shiny(){ for (let i = 0; i < 9; i++) tone(1400 + Math.random() * 1800, 0.4 + i * 0.05, 0.18, "sine", 0.12); tone(1046, 0.45, 0.7, "triangle", 0.15); },
    coin(){ tone(988, 0, 0.08, "square", 0.1); tone(1319, 0.08, 0.25, "square", 0.1); },
    fanfare(){ [523, 659, 784, 1046].forEach((f, i) => tone(f, i * 0.11, i === 3 ? 0.6 : 0.16, "triangle", 0.22)); },
  };
})();
document.addEventListener("pointerdown", () => sfx.unlock(), { passive: true });
