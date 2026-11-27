-- Frame Turni · incassi dal calendario dei ragazzi + report incassi per gli organizzatori
-- Da incollare UNA volta nel SQL editor di Supabase, PRIMA di mettere online le pagine nuove. Si può rieseguire senza danni.
-- Non tocca la funzione del calendario né il vecchio link incassi (incassi.html?k=...): sono funzioni nuove, a parte.
--
-- Come funziona:
--  · nel calendario, scheda "I miei turni", sul turno compare "Inserisci incassi" dal giorno del turno fino a 3 giorni dopo
--    (come il vecchio link);
--  · solo per le piscine (sedi con il nome nascosto ai ragazzi): sui turni del Christmas (nome visibile) non compare;
--  · lo vede solo chi è in squadra come stampatore in quel turno (se nella squadra non c'è nessuno stampatore, tutta la squadra);
--  · ogni turno ha il suo report: si leggono e si salvano solo i dati di quel turno, mai quelli degli altri;
--  · quando il ragazzo tocca "Invia report" il turno risulta inviato (con ora e nome di chi l'ha mandato)
--    e il report "Incassi" nel gestionale si compila da solo;
--  · i ragazzi non leggono mai le tabelle: passano solo da queste funzioni, che controllano chi sono e il turno.

-- 1. chi ha inviato il report e quando
alter table public.tp_incassi add column if not exists inviato_il timestamptz;
alter table public.tp_incassi add column if not exists inviato_da uuid;

-- 2. controllo interno: il collaboratore può compilare gli incassi di questo turno?
create or replace function public.tp_inc_puo(p_collab uuid, p_turno uuid)
 returns boolean
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select exists (
    select 1
      from tp_turni t
      join tp_assegnazioni a on a.turno_id = t.id and a.collaboratore_id = p_collab
      join tp_collaboratori c on c.id = p_collab and c.attivo
      join tp_piscine p on p.id = t.piscina_id and not coalesce(p.nome_visibile, false)
     where t.id = p_turno
       and t.pubblicato and not coalesce(t.annullato, false)
       and t.data <= (now() at time zone 'Europe/Rome')::date
       and t.data >= (now() at time zone 'Europe/Rome')::date - 3
       and (a.ruolo = 'S' or not exists (select 1 from tp_assegnazioni s where s.turno_id = t.id and s.ruolo = 'S'))
  )
$function$;

revoke execute on function public.tp_inc_puo(uuid, uuid) from public, anon, authenticated;

-- 3. i turni di cui il collaboratore può inviare gli incassi adesso (per i tasti nel calendario)
create or replace function public.tp_pub_inc_miei(p_collab uuid)
 returns json
 language sql
 stable security definer
 set search_path to 'public'
as $function$
  select coalesce(json_agg(json_build_object(
      'turno_id', t.id,
      'scade', t.data + 3,
      'inviato_il', (select i.inviato_il from tp_incassi i where i.turno_id = t.id order by i.inviato_il desc nulls last limit 1)
    ) order by t.data, t.ora_inizio), '[]'::json)
    from tp_turni t
   where t.data between (now() at time zone 'Europe/Rome')::date - 3 and (now() at time zone 'Europe/Rome')::date
     and tp_inc_puo(p_collab, t.id)
$function$;

grant execute on function public.tp_pub_inc_miei(uuid) to anon, authenticated;

-- 4. legge il report di UN turno
create or replace function public.tp_pub_inc_leggi(p_collab uuid, p_turno uuid)
 returns json
 language plpgsql
 stable security definer
 set search_path to 'public'
as $function$
declare
  v_t tp_turni%rowtype;
begin
  if not tp_inc_puo(p_collab, p_turno) then
    raise exception 'Gli incassi di questo turno non sono più modificabili: per correzioni scrivi agli organizzatori.';
  end if;
  select * into v_t from tp_turni where id = p_turno;
  return json_build_object(
    'turno_id', v_t.id,
    'piscina', (select p.nome from tp_piscine p where p.id = v_t.piscina_id),
    'data', v_t.data, 'ora_inizio', v_t.ora_inizio, 'ora_fine', v_t.ora_fine,
    'scade', v_t.data + 3,
    'incasso', (select json_build_object('cash', i.cash, 'pos', i.pos, 'percentuale_piscina', i.percentuale_piscina,
                                         'aggiornato_il', i.aggiornato_il, 'inviato_il', i.inviato_il)
                  from tp_incassi i where i.turno_id = p_turno order by i.aggiornato_il desc nulls last limit 1),
    'spese', coalesce((select json_agg(json_build_object('descrizione', s.descrizione, 'importo', s.importo))
                         from tp_spese s where s.turno_id = p_turno), '[]'::json),
    'squadra', coalesce((select json_agg(json_build_object(
                           'assegnazione_id', a.id, 'nome', c.nome, 'ruolo', a.ruolo,
                           'importo', k.importo, 'nota', k.nota) order by a.ruolo desc, c.nome)
                           from tp_assegnazioni a
                           join tp_collaboratori c on c.id = a.collaboratore_id
                           left join tp_compensi k on k.assegnazione_id = a.id
                          where a.turno_id = p_turno), '[]'::json)
  );
end
$function$;

grant execute on function public.tp_pub_inc_leggi(uuid, uuid) to anon, authenticated;

-- 5. salva e invia il report di UN turno (si può rimandare corretto fino a 3 giorni dopo)
create or replace function public.tp_pub_inc_salva(p_collab uuid, p_turno uuid, p_cash numeric, p_pos numeric, p_perc numeric,
                                                   p_spese json, p_compensi json)
 returns json
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
declare
  r json;
  v_aid tp_assegnazioni.id%type;
  v_imp numeric;
  v_nota text;
begin
  if not tp_inc_puo(p_collab, p_turno) then
    raise exception 'Gli incassi di questo turno non sono più modificabili: per correzioni scrivi agli organizzatori.';
  end if;
  if coalesce(p_cash, 0) < 0 or coalesce(p_pos, 0) < 0 or coalesce(p_perc, 0) < 0
     or coalesce(p_cash, 0) > 100000 or coalesce(p_pos, 0) > 100000 or coalesce(p_perc, 0) > 100000 then
    raise exception 'Controlla gli importi.';
  end if;

  update tp_incassi set cash = p_cash, pos = p_pos, percentuale_piscina = p_perc,
                        aggiornato_il = now(), inviato_il = now(), inviato_da = p_collab
   where turno_id = p_turno;
  if not found then
    insert into tp_incassi (turno_id, cash, pos, percentuale_piscina, aggiornato_il, inviato_il, inviato_da)
    values (p_turno, p_cash, p_pos, p_perc, now(), now(), p_collab);
  end if;

  -- spese: si riscrivono tutte quelle del turno
  delete from tp_spese where turno_id = p_turno;
  for r in select * from json_array_elements(coalesce(p_spese, '[]'::json)) loop
    if trim(coalesce(r->>'descrizione', '')) = '' then continue; end if;
    v_imp := nullif(r->>'importo', '')::numeric;
    if v_imp is null or v_imp < 0 or v_imp > 100000 then raise exception 'Controlla l''importo della spesa "%".', r->>'descrizione'; end if;
    insert into tp_spese (turno_id, descrizione, importo) values (p_turno, left(trim(r->>'descrizione'), 120), v_imp);
  end loop;

  -- compensi: solo per le persone in squadra in QUESTO turno
  for r in select * from json_array_elements(coalesce(p_compensi, '[]'::json)) loop
    select a.id into v_aid from tp_assegnazioni a where a.turno_id = p_turno and a.id::text = (r->>'assegnazione_id');
    if not found then continue; end if;
    v_imp := nullif(r->>'importo', '')::numeric;
    v_nota := nullif(left(trim(coalesce(r->>'nota', '')), 200), '');
    if v_imp is not null and (v_imp < 0 or v_imp > 100000) then raise exception 'Controlla i compensi.'; end if;
    if v_imp is null and v_nota is null then
      delete from tp_compensi where assegnazione_id = v_aid;
      continue;
    end if;
    update tp_compensi set importo = v_imp, nota = v_nota, aggiornato_il = now() where assegnazione_id = v_aid;
    if not found then
      insert into tp_compensi (assegnazione_id, importo, nota, aggiornato_il) values (v_aid, v_imp, v_nota, now());
    end if;
  end loop;

  return json_build_object('ok', true, 'inviato_il', now());
end
$function$;

grant execute on function public.tp_pub_inc_salva(uuid, uuid, numeric, numeric, numeric, json, json) to anon, authenticated;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
