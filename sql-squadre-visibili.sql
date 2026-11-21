-- Frame Turni · pagina "Squadre": tutti i turni di un evento con chi c'è, visibile a tutti i collaboratori iscritti
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
-- Non tocca la funzione del calendario: è una funzione nuova, a parte.
--
-- Come funziona:
--  · nel pannello, sulla scheda dell'evento, l'interruttore "Squadre per tutti" (spento di partenza);
--  · se acceso, nel calendario dei ragazzi compare la scheda "Squadre" (link: calendario.html?vista=squadre)
--    con tutti i turni dell'evento da oggi in poi e, per le squadre pubblicate, i nomi e il ruolo (foto/stampa);
--  · risponde solo a chi è iscritto e attivo; arrivano solo i nomi, mai telefono, email o id degli altri.

alter table public.tp_eventi add column if not exists squadre_pubbliche boolean not null default false;

create or replace function public.tp_pub_squadre(p_collab uuid)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select case when not exists (select 1 from tp_collaboratori where id = p_collab and attivo) then null
  else coalesce((
    select json_agg(json_build_object(
        'id', e.id, 'nome', e.nome,
        'turni', coalesce((
          select json_agg(json_build_object(
              'data', t.data, 'ora_inizio', t.ora_inizio, 'ora_fine', t.ora_fine,
              'sede', p.nome, 'colore', p.colore,
              'pubblicato', t.pubblicato, 'annullato', t.annullato, 'motivo', t.motivo_annullo,
              'squadra', case when t.pubblicato and not t.annullato then coalesce((
                  select json_agg(json_build_object('nome', c.nome, 'ruolo', a.ruolo, 'io', c.id = p_collab) order by a.ruolo, c.nome)
                    from tp_assegnazioni a join tp_collaboratori c on c.id = a.collaboratore_id
                   where a.turno_id = t.id), '[]'::json) else '[]'::json end
            ) order by t.data, t.ora_inizio, p.nome)
            from tp_turni t join tp_piscine p on p.id = t.piscina_id
           where t.evento_id = e.id and t.data >= (now() at time zone 'Europe/Rome')::date), '[]'::json)
      ) order by e.data_inizio)
      from tp_eventi e
     where e.squadre_pubbliche), '[]'::json)
  end
$function$;

grant execute on function public.tp_pub_squadre(uuid) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
