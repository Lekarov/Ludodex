function showMsg(text, kind){
  const el = document.getElementById("formMsg");
  el.textContent = text;
  el.className = "msg show " + kind;
}

document.getElementById("newPasswordForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const password = document.getElementById("password").value;
  const password2 = document.getElementById("password2").value;
  const submitBtn = document.getElementById("submitBtn");

  if (password !== password2) { showMsg("Les mots de passe ne correspondent pas.", "error"); return; }
  if (password.length < 8) { showMsg("Le mot de passe doit faire au moins 8 caractères.", "error"); return; }

  submitBtn.disabled = true;
  // Le lien de réinitialisation a déjà ouvert une session temporaire (voir redirectTo) :
  // updateUser change le mot de passe de cette session.
  const { error } = await supabaseClient.auth.updateUser({ password });
  if (error) {
    submitBtn.disabled = false;
    showMsg(error.message, "error");
    return;
  }
  showMsg("Mot de passe mis à jour. Redirection…", "ok");
  setTimeout(() => { window.location.href = "account.html"; }, 1200);
});
