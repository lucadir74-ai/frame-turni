-- Frame Turni · i ragazzi accettano o rifiutano il turno + avvisi WhatsApp
-- Da incollare UNA volta nel SQL editor di Supabase, PRIMA di mettere online le pagine nuove. Si può rieseguire senza danni.
-- Sostituisce la funzione del calendario di sql-indirizzo-squadra.sql: è la stessa, con in più la risposta di chi guarda.
-- (Se in futuro riesegui sql-sedi-nascoste.sql, sql-colleghi-visibili.sql o sql-indirizzo-squadra.sql, poi riesegui anche questo.)
--
-- Come funziona:
--  · quando la squadra è pubblicata, chi è in squadra vede "Accetto" / "Non posso";
--  · Accetto → la risposta resta salvata sull'assegnazione (risposta = 'si');
--  · Non posso (solo se mancano più di 48 ore) → esce dalla squadra, la candidatura a quel turno viene tolta
--    e agli organizzatori compare l'avviso in alto, come per i ritiri ("ha rifiutato il turno, il posto è scoperto");
--  · gli organizzatori vedono chi ha accettato, chi è in attesa e a chi hanno già mandato il WhatsApp.

-- 1. colonne nuove
alter table public.tp_assegnazioni add column if not exists risposta text;
alter table public.tp_assegnazioni add column if not exists risposta_il timestamptz;
alter table public.tp_assegnazioni add column if not exists avvisato_il timestamptz;
alter table public.tp_assegnazioni add column if not exists creato timestamptz not null default now();
alter table public.tp_turni add column if not exists pubblicato_il timestamptz;
alter table public.tp_ritiri add column if not exists tipo text not null default 'ritiro';
-- data di iscrizione dei collaboratori (per metterli in ordine dal più recente). Chi c'era già prende la data di oggi.
alter table public.tp_collaboratori add column if not exists creato timestamptz not null default now();

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tp_assegnazioni_risposta_check') then
    alter table public.tp_assegnazioni add constraint tp_assegnazioni_risposta_check check (risposta in ('si'));
  end if;
end $$;

-- quello che serve dagli script precedenti (se non erano mai stati eseguiti)
alter table public.tp_piscine add column if not exists nome_visibile boolean not null default false;
alter table public.tp_piscine add column if not exists indirizzo text;
alter table public.tp_eventi add column if not exists mostra_colleghi boolean not null default false;

-- 2. risposta del ragazzo: p_si = true accetta, false rifiuta
create or replace function public.tp_pub_risposta(p_collab uuid, p_turno uuid, p_si boolean)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  v_t tp_turni%rowtype;
  v_inizio timestamp;
begin
  if not exists (select 1 from tp_collaboratori where id = p_collab and attivo) then
    raise exception 'Non risulti iscritto: riapri il calendario.';
  end if;
  select * into v_t from tp_turni where id = p_turno;
  if not found or not v_t.pubblicato or v_t.annullato then
    raise exception 'Questo turno non è più disponibile: ricarica il calendario.';
  end if;
  if not exists (select 1 from tp_assegnazioni where turno_id = p_turno and collaboratore_id = p_collab) then
    raise exception 'Non sei più in questa squadra: ricarica il calendario.';
  end if;
  v_inizio := v_t.data::date + v_t.ora_inizio::time;
  if v_inizio <= (now() at time zone 'Europe/Rome') then
    raise exception 'Il turno è già iniziato.';
  end if;

  if p_si then
    update tp_assegnazioni set risposta = 'si', risposta_il = now()
     where turno_id = p_turno and collaboratore_id = p_collab;
    return json_build_object('ok', true, 'risposta', 'si');
  end if;

  if v_inizio - interval '48 hours' <= (now() at time zone 'Europe/Rome') then
    raise exception 'Mancano meno di 48 ore: per rifiutare scrivi a Betty.';
  end if;
  delete from tp_assegnazioni where turno_id = p_turno and collaboratore_id = p_collab;
  delete from tp_candidature where turno_id = p_turno and collaboratore_id = p_collab;
  insert into tp_ritiri (turno_id, collaboratore_id, tipo) values (p_turno, p_collab, 'rifiuto');
  return json_build_object('ok', true, 'risposta', 'no');
end
$function$;

grant execute on function public.tp_pub_risposta(uuid, uuid, boolean) to anon, authenticated;

-- 3. la funzione del calendario (come sql-indirizzo-squadra.sql, più 'mia_risposta')
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
        'mia_risposta', case when t.io_sq then coalesce((select a.risposta from tp_assegnazioni a
            where a.turno_id = t.id and a.collaboratore_id = p_collab limit 1), 'attesa') end,
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
