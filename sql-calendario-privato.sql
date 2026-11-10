-- Frame Turni · calendario riservato agli iscritti
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
--
-- Prima la funzione mandava al browser l'elenco di tutti i collaboratori con il loro id, e con l'id di un collega
-- ci si poteva candidare o ritirare al posto suo. Ora:
--  · risponde solo a chi è iscritto (riceve il proprio id, che conosce soltanto lui);
--  · non manda più l'elenco dei collaboratori né gli id degli altri: di candidati e squadra arriva solo il nome,
--    con io = true sulla riga di chi sta guardando.

drop function if exists public.tp_pub_calendario();

create or replace function public.tp_pub_calendario(p_collab uuid default null)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with io as (select c.id, c.nome from tp_collaboratori c where c.id = p_collab and c.attivo)
  select json_build_object(
    'io', (select json_build_object('id', io.id, 'nome', io.nome) from io),
    'turni', case when exists (select 1 from io) then coalesce((select json_agg(json_build_object(
                'id', t.id, 'data', t.data, 'ora_inizio', t.ora_inizio, 'ora_fine', t.ora_fine,
                'piscina', p.nome, 'piscina_id', p.id, 'colore', p.colore, 'pubblicato', t.pubblicato,
                'annullato', t.annullato, 'motivo', t.motivo_annullo,
                'fotografi', t.fotografi, 'stampatori', t.stampatori,
                'candidati', coalesce((
                    select json_agg(json_build_object('nome', c.nome, 'io', c.id = p_collab) order by k.creata)
                    from tp_candidature k join tp_collaboratori c on c.id = k.collaboratore_id
                    where k.turno_id = t.id), '[]'::json),
                'squadra', case when t.pubblicato then coalesce((
                    select json_agg(json_build_object('nome', c.nome, 'io', c.id = p_collab, 'ruolo', a.ruolo) order by a.ruolo desc, c.nome)
                    from tp_assegnazioni a join tp_collaboratori c on c.id = a.collaboratore_id
                    where a.turno_id = t.id), '[]'::json) else '[]'::json end
              ) order by t.data, t.ora_inizio)
              from tp_turni t join tp_piscine p on p.id = t.piscina_id
              where t.data between tp_oggi() and tp_oggi() + 120), '[]'::json)
             else '[]'::json end
  )
$function$;

grant execute on function public.tp_pub_calendario(uuid) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
