// Inscription email/mot de passe + boutons Google/Discord (nécessitent que ces fournisseurs
// soient activés dans le dashboard Supabase : Authentication → Providers).
function showMsg(text, kind){
  const el = document.getElementById("formMsg");
  el.textContent = text;
  el.className = "msg show " + kind;
}

document.getElementById("signupForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = document.getElementById("email").value.trim();
  const username = document.getElementById("username").value.trim();
  const password = document.getElementById("password").value;
  const password2 = document.getElementById("password2").value;
  const submitBtn = document.getElementById("submitBtn");

  if (password !== password2) { showMsg("Les mots de passe ne correspondent pas.", "error"); return; }
  if (password.length < 8) { showMsg("Le mot de passe doit faire au moins 8 caractères.", "error"); return; }
  // Case à cocher plutôt qu'une date exacte : déclaratif seulement, Doktor ne veut pas collecter
  // de date de naissance (même non stockée côté serveur) — décision actée 29/09/2026.
  if (!document.getElementById("ageConfirm").checked) { showMsg("Tu dois certifier avoir 13 ans ou plus.", "error"); return; }
  if (username.length < 3) { showMsg("Le pseudo doit faire au moins 3 caractères.", "error"); return; }

  submitBtn.disabled = true;
  showMsg("Création du compte…", "ok");

  const { data, error } = await supabaseClient.auth.signUp({ email, password });
  if (error) {
    submitBtn.disabled = false;
    showMsg(error.message, "error");
    return;
  }

  // Le profil est créé automatiquement (trigger handle_new_user) avec un pseudo temporaire
  // basé sur l'email — on le remplace tout de suite par le pseudo choisi. Peut échouer si le
  // pseudo est déjà pris (contrainte unique) : le compte existe quand même, juste avec le
  // pseudo temporaire, modifiable plus tard depuis "Mon compte".
  if (data.user) {
    const { error: profErr } = await supabaseClient
      .from("profiles")
      .update({ username })
      .eq("id", data.user.id);
    if (profErr) {
      showMsg("Compte créé, mais ce pseudo est déjà pris — tu pourras en choisir un autre depuis \"Mon compte\".", "ok");
    }
  }

  if (data.session) {
    window.location.href = "boosters.html";
  } else {
    showMsg("Compte créé ! Vérifie ta boîte mail pour confirmer ton adresse avant de te connecter.", "ok");
  }
});

document.getElementById("oauthGoogle").addEventListener("click", () => {
  supabaseClient.auth.signInWithOAuth({ provider: "google", options: { redirectTo: window.location.origin + "/boosters.html" } });
});
document.getElementById("oauthDiscord").addEventListener("click", () => {
  supabaseClient.auth.signInWithOAuth({ provider: "discord", options: { redirectTo: window.location.origin + "/boosters.html" } });
});
