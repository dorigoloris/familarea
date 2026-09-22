# Mappa adozione frontend → baseline next

La baseline non conserva RPC legacy. Il frontend sarà adattato dopo il reset.

| Area UI precedente | Nuova API baseline |
| --- | --- |
| bootstrap/sessione/profile | `get_current_account`, `get_my_profile`, `update_my_profile`, `get_my_organization`, `update_my_organization` |
| Aree | `create_area`, `get_my_areas`, `get_area`, `update_area`, `delete_area`, `get_area_members`, `add_area_member`, `remove_area_member` |
| Attività globali/Area | `create_activity`, `get_activity`, `get_visible_activities`, `update_activity`, `set_activity_status`, `delete_activity`, `set_activity_assignees` |
| Eventi globali/Area | `create_event`, `get_event`, `get_visible_events`, `update_event`, `set_event_status`, `delete_event`, `set_event_participants` |
| Liste globali/Area | `create_list`, `get_list`, `get_visible_lists`, `update_list`, `delete_list`, `create_list_item`, `update_list_item`, `delete_list_item` |
| Scadenze | `create_deadline`, `get_deadline`, `get_my_deadlines`, `update_deadline`, `delete_deadline`, `get_deadline_occurrences`, `complete_deadline_occurrence` |
| Contatti | `create_contact`, `get_contact`, `get_my_contacts`, `update_contact`, `delete_contact`, `replace_contact_methods` |
| Famiglia | `get_my_family`, `create_family`, `create_family_member`, `update_family_member`, `delete_family_member` |
| Interessi | `get_interest_catalog`, `get_my_interests`, `add_my_interest`, `remove_my_interest`, `submit_my_interest_category_proposal` |
| Inviti Area | `create_area_invite`, `get_my_area_invites`, `get_area_invites`, `accept_area_invite`, `decline_area_invite`, `revoke_area_invite` |
| Allegati | upload nel path consentito, poi `register_attachment`; lettura `get_attachments`; rimozione `delete_attachment` |
| Dashboard / Calendario | `get_dashboard`, `get_calendar_occurrences`; entrambe espandono server-side le ricorrenze Activity/Event nel solo intervallo richiesto. `get_dashboard.todos` contiene le Activity `open` senza date. |

I form Area usano il singolo parametro facoltativo `p_area_id`: `NULL` crea un
oggetto standalone del Current Account; un UUID crea un oggetto Area dopo la
verifica server-side del permesso. Non esistono famiglie duplicate `*_my_*` /
`*_area_*`.

Stato frontend: Attività, Eventi, Liste e Calendario usano esclusivamente le
RPC sopra indicate. Attività/Eventi Area leggono assegnatari e partecipanti
tramite `get_activity_assignees` e `get_event_participants`; il Calendario usa
le sole occorrenze già espanse dal server.
