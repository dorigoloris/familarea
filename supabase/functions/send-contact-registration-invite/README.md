# `send-contact-registration-invite`

V1 riceve soltanto `contact_id` dal browser autenticato. La RPC
`get_my_contact_invitation_delivery` verifica server-side che il Contact
appartenga a un account personale, legge l'email primaria e ricava il nome del
mittente dal suo Profile. Non esistono token, inviti persistenti o collegamenti
automatici Contact → Profile.

## Configurazione richiesta prima del primo invio reale

Impostare per la funzione Edge:

- `SITE_URL`: URL HTTPS pubblico della root FamilArea.
- `CONTACT_REGISTRATION_INVITE_FROM`: mittente già verificato presso il provider.
- `CONTACT_REGISTRATION_INVITE_DELIVERY_URL`: endpoint HTTPS del provider/adattatore
  email; riceve `POST` JSON con `from`, `to`, `subject`, `text`, `html`.
- `CONTACT_REGISTRATION_INVITE_DELIVERY_BEARER_TOKEN`: segreto dell'adattatore.

Il provider non è scelto né incluso nel repository. Senza URL e segreto la
funzione risponde `503 email_delivery_not_configured`; nessuna email viene
inviata e nessun dato applicativo viene creato.
