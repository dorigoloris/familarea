# FamilArea baseline next

Questi file sono una baseline locale non applicabile automaticamente da Supabase CLI.
Non sono migration del progetto corrente. Saranno promossi in una nuova cronologia
solo dopo il reset remoto approvato e la riconciliazione della history migration.

Ordine previsto: `familarea_baseline.sql`, `familarea_api.sql`,
`familarea_storage.sql`, `seed_interest_catalog.sql`.

`familarea_api.sql` è l'unica superficie applicativa da esporre al ruolo
`authenticated`: le tabelle restano senza grant diretti. La directory resta
non eseguibile dalla CLI fino al reset approvato e alla nuova history.

L'integrità Account/sottotipo usa constraint trigger DEFERRABLE: al commit un
account personale deve avere esattamente un Profile account-linked e nessuna
Organization; un account Organization deve avere esattamente una Organization
e nessun Profile account-linked. I managed profile hanno `account_id NULL`.
