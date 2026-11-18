-- Frame Turni · scheda "Profilo" nel calendario dei ragazzi
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
--
-- Ognuno vede e cambia SOLO i propri dati, riconosciuto dal codice salvato sul suo telefono all'iscrizione
-- (lo stesso con cui si candida: agli altri non arriva mai).
-- Può cambiare: telefono, email, macchina, cosa fa (foto / stampa / entrambi).
-- Non può cambiare: il nome (lo correggono gli organizzatori) e il livello (non lo vede nemmeno).
-- Gli organizzatori vedono "dati aggiornati il …" nella scheda Collaboratori.

alter table public.tp_collaboratori add column if not exists aggiornato_il timestamptz;

-- legge il proprio profilo
create or replace function public.tp_pub_profilo(p_collab uuid)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select json_build_object('nome', c.nome, 'telefono', c.telefono, 'email', c.email, 'ruolo', c.ruolo, 'auto', c.auto)
    from tp_collaboratori c where c.id = p_collab and c.attivo
$function$;

-- salva il proprio profilo
create or replace function public.tp_pub_salva_profilo(p_collab uuid, p_telefono text, p_email text, p_ruolo text, p_auto boolean)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_tel text := btrim(coalesce(p_telefono, ''));
  v_mail text := lower(btrim(coalesce(p_email, '')));
begin
  if not exists (select 1 from tp_collaboratori where id = p_collab and attivo) then
    raise exception 'Non risulti iscritto: riapri il calendario.';
  end if;
  if length(regexp_replace(v_tel, '\D', '', 'g')) < 8 then
    raise exception 'Il numero di telefono non sembra giusto.';
  end if;
  if v_mail !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(v_mail) > 120 then
    raise exception 'L''email non sembra giusta.';
  end if;
  if p_ruolo not in ('F', 'S', 'FS') then
    raise exception 'Scegli cosa fai: foto, stampa o entrambi.';
  end if;
  -- niente doppioni: telefono o email già di un altro collaboratore
  if exists (select 1 from tp_collaboratori where id <> p_collab
               and right(regexp_replace(coalesce(telefono, ''), '\D', '', 'g'), 9) = right(regexp_replace(v_tel, '\D', '', 'g'), 9)) then
    raise exception 'Questo numero è già di un altro collaboratore: scrivi a Betty.';
  end if;
  if exists (select 1 from tp_collaboratori where id <> p_collab and lower(btrim(coalesce(email, ''))) = v_mail) then
    raise exception 'Questa email è già di un altro collaboratore: scrivi a Betty.';
  end if;

  update tp_collaboratori
     set telefono = v_tel, email = v_mail, ruolo = p_ruolo, auto = coalesce(p_auto, false), aggiornato_il = now()
   where id = p_collab;
  return json_build_object('ok', true);
end
$function$;

grant execute on function public.tp_pub_profilo(uuid) to anon, authenticated;
grant execute on function public.tp_pub_salva_profilo(uuid, text, text, text, boolean) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
