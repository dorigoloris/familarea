export type InvitationEmailKind = "album" | "contact_connection" | "registration";

export type InvitationEmailOptions = {
  kind: InvitationEmailKind;
  senderName: string;
  href: string;
  subject: string;
  title: string;
  intro: string;
  contentTitle?: string;
  buttonLabel: string;
  afterClick: string;
  privacyNote?: string;
  /** A server-created Resend CID, never an original-image URL. */
  albumCoverCid?: string;
  /** Server-created CIDs for selected photo previews, never original-image URLs. */
  albumPhotoCids?: string[];
};

export type InvitationEmail = { subject: string; text: string; html: string };

export function singleLine(value: unknown, fallback = "") {
  return String(value ?? "").replace(/[\r\n]+/g, " ").replace(/\s+/g, " ").trim() || fallback;
}

function escapeHtml(value: unknown) {
  return String(value ?? "").replace(/[&<>"']/g, (character) => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;"
  }[character] ?? character));
}

function albumPhotoGrid(cids: string[]) {
  if (!cids.length) return "";

  const cells = [...cids];
  while (cells.length % 3) cells.push("");
  const rows = [];
  for (let offset = 0; offset < cells.length; offset += 3) {
    const row = cells.slice(offset, offset + 3).map((cid) => cid
      ? `<td width="33.333%" valign="top" style="padding:4px;"><img src="cid:${escapeHtml(cid)}" width="160" alt="Fotografia condivisa" style="display:block;width:100%;max-width:160px;height:auto;max-height:120px;border:0;border-radius:10px;outline:none;text-decoration:none;"></td>`
      : `<td width="33.333%" style="padding:4px;">&nbsp;</td>`).join("");
    rows.push(`<tr>${row}</tr>`);
  }

  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#e8f1f8;border-radius:18px;"><tr><td style="padding:12px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:collapse;">${rows.join("")}</table></td></tr></table>`;
}

function visual(kind: InvitationEmailKind, albumCoverCid = "", albumPhotoCids: string[] = []) {
  if (kind === "album") {
    const photoGrid = albumPhotoGrid(albumPhotoCids);
    if (photoGrid) return photoGrid;
    if (albumCoverCid) {
      return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#e8f1f8;border-radius:18px;"><tr><td align="center" style="padding:16px;"><img src="cid:${escapeHtml(albumCoverCid)}" width="536" alt="Anteprima della copertina dell'Album" style="display:block;width:100%;max-width:536px;height:auto;border:0;border-radius:14px;outline:none;text-decoration:none;"></td></tr></table>`;
    }
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#e8f1f8;border-radius:18px;"><tr><td align="center" style="padding:30px 24px 28px;"><div style="display:inline-block;width:54px;height:54px;line-height:54px;border-radius:18px;background:#4d8b4f;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:25px;font-weight:700;text-align:center;">✦</div><p style="margin:15px 0 0;color:#244563;font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:700;line-height:1.4;">Un ricordo speciale ti sta aspettando</p><p style="margin:5px 0 0;color:#587087;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:1.5;">La copertina sarà visibile in sicurezza dopo l’accettazione.</p></td></tr></table>`;
  }
  if (kind === "contact_connection") {
    return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#edf5ed;border-radius:18px;"><tr><td align="center" style="padding:30px 24px;"><span style="display:inline-block;width:48px;height:48px;line-height:48px;border-radius:50%;background:#4d8b4f;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:20px;font-weight:700;text-align:center;">●</span><span style="display:inline-block;padding:0 8px;color:#4d8b4f;font-family:Arial,Helvetica,sans-serif;font-size:23px;vertical-align:middle;">↔</span><span style="display:inline-block;width:48px;height:48px;line-height:48px;border-radius:50%;background:#244563;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:20px;font-weight:700;text-align:center;">●</span><p style="margin:15px 0 0;color:#244563;font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:700;line-height:1.4;">Un collegamento personale, alle tue condizioni</p></td></tr></table>`;
  }
  return `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="border-collapse:separate;background:#eef4f8;border-radius:18px;"><tr><td align="center" style="padding:30px 24px;"><div style="display:inline-block;width:58px;height:58px;line-height:58px;border-radius:19px;background:#244563;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:21px;font-weight:700;text-align:center;">FA</div><p style="margin:15px 0 0;color:#244563;font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:700;line-height:1.4;">Uno spazio semplice per ciò che conta</p></td></tr></table>`;
}

export function buildInvitationEmail(options: InvitationEmailOptions): InvitationEmail {
  const senderName = singleLine(options.senderName, "Una persona che conosci");
  const subject = singleLine(options.subject, "Hai ricevuto un invito su FamilArea");
  const href = String(options.href || "").trim();
  const title = singleLine(options.title);
  const intro = singleLine(options.intro);
  const contentTitle = singleLine(options.contentTitle);
  const buttonLabel = singleLine(options.buttonLabel, "Apri invito");
  const afterClick = singleLine(options.afterClick);
  const privacyNote = singleLine(options.privacyNote);
  const albumCoverCid = options.kind === "album" && /^[A-Za-z0-9._-]{1,127}$/.test(options.albumCoverCid || "")
    ? options.albumCoverCid
    : "";
  const albumPhotoCids = options.kind === "album" && Array.isArray(options.albumPhotoCids)
    ? [...new Set(options.albumPhotoCids.filter((cid): cid is string => typeof cid === "string" && /^[A-Za-z0-9._-]{1,127}$/.test(cid)))].slice(0, 9)
    : [];
  const textLines = [
    "FamilArea",
    "",
    title,
    intro,
    contentTitle ? `Contenuto: ${contentTitle}` : "",
    "",
    afterClick,
    privacyNote,
    "",
    `${buttonLabel}: ${href}`,
    "",
    "Se non ti aspettavi questo invito, puoi ignorare questa email."
  ].filter(Boolean);

  const contentCard = contentTitle
    ? `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:22px 0 0;border-collapse:separate;background:#f7fafb;border:1px solid #dce7ed;border-radius:14px;"><tr><td style="padding:17px 18px;"><p style="margin:0 0 5px;color:#64758a;font-family:Arial,Helvetica,sans-serif;font-size:11px;font-weight:700;letter-spacing:1px;text-transform:uppercase;">Condiviso con te</p><p style="margin:0;color:#0d2b4f;font-family:Arial,Helvetica,sans-serif;font-size:18px;font-weight:700;line-height:1.35;">${escapeHtml(contentTitle)}</p></td></tr></table>`
    : "";
  const privacyBlock = privacyNote
    ? `<p style="margin:18px 0 0;color:#587087;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:1.55;">${escapeHtml(privacyNote)}</p>`
    : "";

  const html = `<!doctype html><html lang="it"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="x-apple-disable-message-reformatting"><title>${escapeHtml(subject)}</title></head><body style="margin:0;padding:0;background:#f4f8fb;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;border-collapse:collapse;background:#f4f8fb;"><tr><td align="center" style="padding:32px 14px;"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="width:100%;max-width:600px;border-collapse:separate;background:#ffffff;border:1px solid #dce7ed;border-radius:22px;overflow:hidden;"><tr><td style="padding:27px 32px 22px;border-bottom:1px solid #e7edf2;"><span style="font-family:Arial,Helvetica,sans-serif;font-size:27px;font-weight:800;letter-spacing:-1.2px;color:#0d2b4f;">Famil<span style="color:#4d8b4f;">Area</span></span><p style="margin:7px 0 0;color:#64758a;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.4;">Condividere ciò che conta, con le persone giuste.</p></td></tr><tr><td style="padding:30px 32px 12px;">${visual(options.kind, albumCoverCid, albumPhotoCids)}<p style="margin:28px 0 0;color:#0d2b4f;font-family:Arial,Helvetica,sans-serif;font-size:28px;font-weight:700;letter-spacing:-.7px;line-height:1.18;">${escapeHtml(title)}</p><p style="margin:13px 0 0;color:#405872;font-family:Arial,Helvetica,sans-serif;font-size:16px;line-height:1.6;">${escapeHtml(intro)}</p>${contentCard}${privacyBlock}<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:28px 0 0;border-collapse:separate;"><tr><td align="center" bgcolor="#4d8b4f" style="border-radius:11px;"><a href="${escapeHtml(href)}" style="display:inline-block;padding:14px 22px;border:1px solid #4d8b4f;border-radius:11px;color:#ffffff;font-family:Arial,Helvetica,sans-serif;font-size:16px;font-weight:700;line-height:1.2;text-decoration:none;">${escapeHtml(buttonLabel)}</a></td></tr></table><p style="margin:14px 0 24px;color:#64758a;font-family:Arial,Helvetica,sans-serif;font-size:13px;line-height:1.55;">${escapeHtml(afterClick)}</p></td></tr><tr><td style="padding:19px 32px 25px;border-top:1px solid #e7edf2;"><p style="margin:0;color:#7b8c9a;font-family:Arial,Helvetica,sans-serif;font-size:12px;line-height:1.5;">Se non ti aspettavi questo invito, puoi ignorare questa email.</p></td></tr></table></td></tr></table></body></html>`;
  return { subject, text: textLines.join("\n"), html };
}
