-- Frame Turni · modalità dell'evento ("mattina + pomeriggio" oppure "tutto il giorno")
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
--
-- modalita = 'mp'     → turni di mattina e/o pomeriggio (orari in m_inizio/m_fine e p_inizio/p_fine)
-- modalita = 'giorno' → un turno unico per giorno (orari in m_inizio/m_fine, p_inizio/p_fine vuoti)
-- Le pagine funzionano anche prima di eseguire questo script (la modalità viene dedotta dagli orari),
-- ma con la colonna la scelta resta salvata in modo esplicito.

alter table public.tp_eventi
  add column if not exists modalita text not null default 'mp';

do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'tp_eventi_modalita_check') then
    alter table public.tp_eventi
      add constraint tp_eventi_modalita_check check (modalita in ('mp','giorno'));
  end if;
end $$;

-- eventi già esistenti con un solo turno che copre la pausa (inizio prima delle 13, fine dalle 15): sono "tutto il giorno"
update public.tp_eventi
   set modalita = 'giorno'
 where modalita = 'mp' and p_inizio is null and m_inizio < '13:00' and m_fine >= '15:00';

-- fa rileggere subito lo schema all'API (altrimenti la colonna nuova si vede dopo qualche minuto)
notify pgrst, 'reload schema';
