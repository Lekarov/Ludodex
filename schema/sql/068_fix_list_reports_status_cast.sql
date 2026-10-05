-- Ludodex Online — 068 : corrige list_reports() (063_admin_hub_actions.sql), qui comparait
-- directement le paramètre p_status (text) à message_reports.status (enum report_status) — Postgres
-- n'a pas d'opérateur "=" entre report_status et text sans cast explicite, d'où l'erreur "operator
-- does not exist: report_status = text" constatée par Doktor dès qu'on ouvre l'onglet Signalements.
create or replace function public.list_reports(p_status text default 'pending')
returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_result jsonb;
begin
  perform public._require_elevated();
  select coalesce(jsonb_agg(row_to_json(t)), '[]'::jsonb) into v_result from (
    select r.id, r.reason, r.status, r.created_at,
           reporter.username as reporter_username,
           m.content as message_content, m.created_at as message_created_at,
           sender.username as sender_username, sender.id as sender_id
    from public.message_reports r
    join public.profiles reporter on reporter.id = r.reporter_id
    join public.private_messages m on m.id = r.message_id
    join public.profiles sender on sender.id = m.sender_id
    where p_status is null or r.status = p_status::report_status
    order by r.created_at desc
    limit 100
  ) t;
  return v_result;
end;
$$;
