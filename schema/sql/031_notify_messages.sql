-- Ludodex Online — 031 : notification à la réception d'un message privé
-- private_messages est écrite directement par le client (pas de RPC, voir 007), donc on ne peut
-- pas insérer la notification "à la main" dans une fonction serveur comme pour le marché/succès :
-- un trigger AFTER INSERT s'en charge. link_id = l'expéditeur, pour que le client ouvre
-- directement la conversation avec lui (messages.html?with=<profile_id>).

create or replace function public.notify_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sender text;
begin
  select username into v_sender from public.profiles where id = new.sender_id;
  perform public.create_notification(
    new.recipient_id, 'message', 'Nouveau message',
    coalesce(v_sender, 'Un joueur') || ' t''a envoyé un message.',
    'message', new.sender_id::text
  );
  return new;
end;
$$;

drop trigger if exists trg_notify_new_message on public.private_messages;
create trigger trg_notify_new_message
  after insert on public.private_messages
  for each row execute function public.notify_new_message();
