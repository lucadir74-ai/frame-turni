-- Frame Turni · indirizzo della piscina a chi è in squadra
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
-- Sostituisce la funzione del calendario di sql-colleghi-visibili.sql: è la stessa, con in più l'indirizzo.
-- (Se in futuro riesegui sql-sedi-nascoste.sql o sql-colleghi-visibili.sql, poi riesegui anche questo.)
--
-- L'indirizzo della sede (scheda Sedi) arriva SOLO a chi è nella squadra pubblicata di quel turno,
-- e solo per le sedi nascoste (le piscine). Christmas World e le altre sedi con nome visibile restano come prima.

-- quello che serve dagli script precedenti (se non erano mai stati eseguiti)
alter table public.tp_piscine
  add column if not exists nome_visibile boolean not null default false;
alter table public.tp_piscine
  add column if not exists indirizzo text;
alter table public.tp_eventi
  add column if not exists mostra_colleghi boolean not null default false;

create or replace function public.tp_pub_calendario(p_collab uuid default null)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with io as (select c.id, c.nome from tp_collaboratori c where c.id = p_collab and c.attivo),
  t0 as (
    select t.*, p.nome as p_nome, p.colore as p_colore, p.indirizzo as p_indirizzo,
           coalesce(p.nome_visibile, false) as vis,
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
        'indirizzo', case when t.io_sq and not t.vis then t.p_indirizzo end,
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
