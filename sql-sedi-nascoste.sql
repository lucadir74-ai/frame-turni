-- Frame Turni · calendario dei ragazzi riservato e con sedi nascoste
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
-- Comprende anche sql-calendario-privato.sql: basta eseguire questo (anche se l'altro è già stato eseguito).
--
-- La funzione tp_pub_calendario(p_collab):
--  · risponde solo a chi è iscritto e attivo (riceve il proprio id, che conosce soltanto lui);
--  · non manda l'elenco dei collaboratori, né gli id degli altri, né chi si è candidato:
--    di ogni turno dice solo se chi guarda è candidato (mio_cand);
--  · per le sedi senza "nome visibile" (le piscine) non manda nome, colore né squadra:
--    il nome lo riceve solo chi è nella squadra pubblicata di quel turno (deve sapere dove andare);
--  · la squadra pubblicata arriva con i nomi, con io = true sulla riga di chi guarda.

-- 1. spunta "nome visibile ai collaboratori" sulle sedi (di base NO); Christmas World resta riconoscibile
alter table public.tp_piscine
  add column if not exists nome_visibile boolean not null default false;

update public.tp_piscine set nome_visibile = true where nome ilike '%christmas%';

-- 2. via le versioni precedenti della funzione
drop function if exists public.tp_pub_calendario();
drop function if exists public.tp_pub_calendario_io(text);

create or replace function public.tp_pub_calendario(p_collab uuid default null)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  with io as (select c.id, c.nome from tp_collaboratori c where c.id = p_collab and c.attivo),
  t as (
    select t.*, p.nome as p_nome, p.colore as p_colore, coalesce(p.nome_visibile, false) as vis,
           (t.pubblicato and exists (select 1 from tp_assegnazioni a
              where a.turno_id = t.id and a.collaboratore_id = p_collab)) as io_sq
      from tp_turni t join tp_piscine p on p.id = t.piscina_id
     where t.data between (now() at time zone 'Europe/Rome')::date - 31
                      and (now() at time zone 'Europe/Rome')::date + 120
  )
  select json_build_object(
    'io', (select json_build_object('id', io.id, 'nome', io.nome) from io),
    'turni', case when exists (select 1 from io) then coalesce((select json_agg(json_build_object(
        'id', t.id, 'data', t.data, 'ora_inizio', t.ora_inizio, 'ora_fine', t.ora_fine,
        'visibile', t.vis,
        'piscina', case when t.vis or t.io_sq then t.p_nome end,
        'piscina_id', case when t.vis then t.piscina_id end,
        'colore', case when t.vis then t.p_colore end,
        'pubblicato', t.pubblicato, 'annullato', t.annullato, 'motivo', t.motivo_annullo,
        'fotografi', case when t.vis then t.fotografi end,
        'stampatori', case when t.vis then t.stampatori end,
        'mio_cand', exists (select 1 from tp_candidature k where k.turno_id = t.id and k.collaboratore_id = p_collab),
        'squadra', case when t.pubblicato and (t.vis or t.io_sq) then coalesce((
            select json_agg(json_build_object('nome', c.nome, 'io', c.id = p_collab, 'ruolo', a.ruolo) order by a.ruolo desc, c.nome)
              from tp_assegnazioni a join tp_collaboratori c on c.id = a.collaboratore_id
             where a.turno_id = t.id), '[]'::json) else '[]'::json end
      ) order by t.data, t.ora_inizio) from t), '[]'::json)
    else '[]'::json end
  )
$function$;

grant execute on function public.tp_pub_calendario(uuid) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
