-- Frame Turni · link del gruppo WhatsApp di ogni turno
-- Da incollare UNA volta nel SQL editor di Supabase. Si può rieseguire senza danni.
--
-- Dopo aver pubblicato una squadra, dal pannello ("Gruppo WhatsApp" sul turno) l'organizzatore crea il gruppo
-- dal telefono, incolla qui il link d'invito e manda ai ragazzi il messaggio con il link per entrare.
-- Il link resta salvato sul turno: lo vedono tutti gli organizzatori ed entra anche negli avvisi "Avvisa la squadra".
-- Senza questo script la finestra funziona lo stesso, ma il link non resta salvato.

alter table public.tp_turni add column if not exists gruppo_link text;

-- fa rileggere subito lo schema all'API
notify pgrst, 'reload schema';
