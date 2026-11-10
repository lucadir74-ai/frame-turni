-- Frame Turni · sedi nascoste ai collaboratori
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
--
-- 1. Ogni sede ha la spunta "nome visibile ai collaboratori" (di base NO).
--    Solo le sedi con la spunta (es. Christmas World) si vedono per nome nel calendario dei ragazzi;
--    le altre (le piscine) compaiono solo come "Turno" nella giornata, senza nome.
-- 2. Nuova funzione per il calendario dei ragazzi: non manda più i nomi dei candidati
--    né il nome delle sedi nascoste. Il nome della sede arriva solo a chi è nella squadra pubblicata
--    (deve sapere dove andare).
-- 3. La vecchia funzione tp_pub_calendario (che mandava candidati e sedi a chiunque) viene chiusa al pubblico.

alter table public.tp_piscine
  add column if not exists nome_visibile boolean not null default false;

-- Christmas World resta riconoscibile
update public.tp_piscine set nome_visibile = true where nome ilike '%christmas%';

create or replace function public.tp_pub_calendario_io(p_collab text default null)
returns json
language sql
stable
security definer
set search_path = public
as $$
  with t as (
    select t.*, p.nome as p_nome, p.colore as p_colore, coalesce(p.nome_visibile,false) as vis,
           (t.pubblicato and exists(select 1 from tp_assegnazioni a
              where a.turno_id = t.id and a.collaboratore_id::text = p_collab)) as io_sq
      from tp_turni t
      join tp_piscine p on p.id = t.piscina_id
     where t.data >= current_date - 45
  )
  select json_build_object(
    'staff', coalesce((select json_agg(json_build_object('id', c.id, 'nome', c.nome) order by c.nome)
                         from tp_collaboratori c where c.attivo), '[]'::json),
    'turni', coalesce((select json_agg(json_build_object(
        'id', t.id, 'data', t.data, 'ora_inizio', t.ora_inizio, 'ora_fine', t.ora_fine,
        'fotografi', t.fotografi, 'stampatori', t.stampatori,
        'annullato', t.annullato, 'motivo', t.motivo_annullo, 'pubblicato', t.pubblicato,
        'visibile', t.vis,
        'piscina', case when t.vis or t.io_sq then t.p_nome end,
        'piscina_id', case when t.vis then t.piscina_id end,
        'colore', case when t.vis then t.p_colore end,
        'mio_cand', exists(select 1 from tp_candidature k
                            where k.turno_id = t.id and k.collaboratore_id::text = p_collab),
        'squadra', case when t.pubblicato and (t.vis or t.io_sq) then
            coalesce((select json_agg(json_build_object('id', a.collaboratore_id, 'nome', c.nome, 'ruolo', a.ruolo))
                        from tp_assegnazioni a join tp_collaboratori c on c.id = a.collaboratore_id
                       where a.turno_id = t.id), '[]'::json)
          else '[]'::json end
      ) order by t.data, t.ora_inizio) from t), '[]'::json)
  );
$$;

grant execute on function public.tp_pub_calendario_io(text) to anon, authenticated;

-- la vecchia funzione non serve più alle pagine: la si chiude al pubblico
do $$
declare f regprocedure;
begin
  for f in select oid::regprocedure from pg_proc
            where proname = 'tp_pub_calendario' and pronamespace = 'public'::regnamespace loop
    execute format('revoke execute on function %s from public, anon', f);
  end loop;
end $$;

notify pgrst, 'reload schema';
