function showMsg(text, kind){
  const el = document.getElementById("formMsg");
  el.textContent = text;
  el.className = "msg show " + kind;
}

document.getElementById("resetForm").addEventListener("submit", async (e) => {
  e.preventDefault();
  const email = document.getElementById("email").value.trim();
  const submitBtn = document.getElementById("submitBtn");
  submitBtn.disabled = true;

  const { error } = await supabaseClient.auth.resetPasswordForEmail(email, {
    redirectTo: window.location.origin + "/reset-password.html",
  });
  if (error) {
    submitBtn.disabled = false;
    showMsg(error.message, "error");
    return;
  }
  showMsg("Si un compte existe avec cet email, un lien de réinitialisation vient d'être envoyé.", "ok");
});
