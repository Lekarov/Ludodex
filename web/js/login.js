function showMsg(text, kind){
  const el = document.getElementById("formMsg");
  el.textContent = text;
  el.className = "msg show " + kind;
}

document.getElementById("loginForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = document.getElementById("email").value.trim();
  const password = document.getElementById("password").value;
  const submitBtn = document.getElementById("submitBtn");

  submitBtn.disabled = true;
  showMsg("Connexion…", "ok");

  const { error } = await supabaseClient.auth.signInWithPassword({ email, password });
  if (error) {
    submitBtn.disabled = false;
    showMsg(error.message === "Invalid login credentials" ? "Email ou mot de passe incorrect." : error.message, "error");
    return;
  }
  window.location.href = "boosters.html";
});

document.getElementById("oauthGoogle").addEventListener("click", () => {
  supabaseClient.auth.signInWithOAuth({ provider: "google", options: { redirectTo: window.location.origin + "/boosters.html" } });
});
document.getElementById("oauthDiscord").addEventListener("click", () => {
  supabaseClient.auth.signInWithOAuth({ provider: "discord", options: { redirectTo: window.location.origin + "/boosters.html" } });
});
