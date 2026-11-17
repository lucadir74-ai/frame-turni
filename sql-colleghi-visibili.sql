-- Frame Turni · "colleghi visibili" per evento
-- Da incollare UNA volta nel SQL editor di Supabase, DOPO sql-sedi-nascoste.sql. Si può rieseguire senza danni.
-- (Se in futuro riesegui sql-sedi-nascoste.sql, poi riesegui anche questo: altrimenti torna la versione vecchia.)
--
-- Sull'evento c'è l'interruttore mostra_colleghi (di base NO), che gli organizzatori accendono dalla pagina.
-- Nel calendario dei ragazzi, a squadra pubblicata:
--  · interruttore SPENTO → ognuno vede solo i propri turni (quando è in squadra lui), senza i nomi degli altri;
--  · interruttore ACCESO → chi è in squadra in una giornata dell'evento vede chi lavora in quella giornata
--    (la squadra di tutti i turni pubblicati dell'evento in quel giorno, mattina e pomeriggio).
-- Chi non è in squadra quel giorno non vede i nomi di nessuno.

-- 0. quello che serve di sql-sedi-nascoste.sql (se non era mai stato eseguito): "nome visibile" sulle sedi,
--    Christmas resta riconoscibile, via le versioni vecchie della funzione
alter table public.tp_piscine
  add column if not exists nome_visibile boolean not null default false;
update public.tp_piscine set nome_visibile = true where nome ilike '%christmas%' and not nome_visibile;
drop function if exists public.tp_pub_calendario();
drop function if exists public.tp_pub_calendario_io(text);

-- 1. l'interruttore sull'evento
alter table public.tp_eventi
  add column if not exists mostra_colleghi boolean not null default false;

-- 2. la funzione del calendario
create or replace function public.tp_pub_calendario(p_collab uuid default null)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with io as (select c.id, c.nome from tp_collaboratori c where c.id = p_collab and c.attivo),
  t0 as (
    select t.*, p.nome as p_nome, p.colore as p_colore, coalesce(p.nome_visibile, false) as vis,
           coalesce(e.mostra_colleghi, false) as colleghi,
           (t.pubblicato and exists (select 1 from tp_assegnazioni a
              where a.turno_id = t.id and a.collaboratore_id = p_collab)) as io_sq
      from tp_turni t
      join tp_piscine p on p.id = t.piscina_id
      left join tp_eventi e on e.id = t.evento_id
     where t.data between (now() at time zone 'Europe/Rome')::date - 31
                      and (now() at time zone 'Europe/Rome')::date + 120
  ),
  -- io_giorno: interruttore acceso e chi guarda è in squadra in un altro turno dello stesso evento, stesso giorno
  t as (
    select t0.*, (t0.pubblicato and t0.colleghi and not t0.io_sq and exists (
             select 1 from t0 x where x.io_sq and x.data = t0.data and x.evento_id = t0.evento_id)) as io_giorno
      from t0
  )
  select json_build_object(
    'io', (select json_build_object('id', io.id, 'nome', io.nome) from io),
    'turni', case when exists (select 1 from io) then coalesce((select json_agg(json_build_object(
        'id', t.id, 'data', t.data, 'ora_inizio', t.ora_inizio, 'ora_fine', t.ora_fine,
        'visibile', t.vis,
        'piscina', case when t.vis or t.io_sq or t.io_giorno then t.p_nome end,
        'piscina_id', case when t.vis then t.piscina_id end,
        'colore', case when t.vis then t.p_colore end,
        'pubblicato', t.pubblicato, 'annullato', t.annullato, 'motivo', t.motivo_annullo,
        'fotografi', case when t.vis then t.fotografi end,
        'stampatori', case when t.vis then t.stampatori end,
        'colleghi', t.colleghi,
        'mio_cand', exists (select 1 from tp_candidature k where k.turno_id = t.id and k.collaboratore_id = p_collab),
        'squadra', case when t.io_sq or t.io_giorno then coalesce((
            select json_agg(json_build_object('nome', c.nome, 'io', c.id = p_collab, 'ruolo', a.ruolo) order by a.ruolo desc, c.nome)
              from tp_assegnazioni a join tp_collaboratori c on c.id = a.collaboratore_id
             where a.turno_id = t.id and (t.colleghi or a.collaboratore_id = p_collab)), '[]'::json) else '[]'::json end
      ) order by t.data, t.ora_inizio) from t), '[]'::json)
    else '[]'::json end
  )
$function$;

grant execute on function public.tp_pub_calendario(uuid) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
