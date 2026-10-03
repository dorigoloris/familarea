(function () {
  const attachmentPreview = window.FamilAreaAttachmentPreview;

  function formatAttachmentSize(bytes) {
    const size = Number(bytes) || 0;
    if (size < 1024 * 1024) return `${Math.max(1, Math.round(size / 1024))} KB`;
    return `${(size / (1024 * 1024)).toLocaleString('it-IT', {
      minimumFractionDigits: 1,
      maximumFractionDigits: 1
    })} MB`;
  }

  function create({ client, deadlineId, input, uploadControl, message, empty, list }) {
    let uploadInProgress = false;

    function setMessage(text = '', isError = false) {
      message.textContent = text;
      message.classList.toggle('is-error', isError);
    }

    function setUploadInProgress(inProgress) {
      uploadInProgress = inProgress;
      input.disabled = inProgress;
      uploadControl.setAttribute('aria-disabled', String(inProgress));
    }

    async function openAttachment(attachment, button) {
      button.disabled = true;
      const { data, error } = await client.storage
        .from('familarea-attachments')
        .createSignedUrl(attachment.storage_path, 60);
      button.disabled = false;
      if (error || !data?.signedUrl) {
        setMessage('Non è stato possibile aprire l’allegato. Riprova.', true);
        return;
      }
      window.open(data.signedUrl, '_blank', 'noopener');
    }

    async function removeAttachment(attachment, button) {
      const confirmed = await FamilAreaConfirm.confirm({
        variant: 'danger',
        title: 'Eliminare l’allegato?',
        message: `“${attachment.original_filename}” verrà eliminato definitivamente.`,
        confirmText: 'Elimina'
      });
      if (!confirmed) return;

      button.disabled = true;
      const result = await client.rpc('delete_attachment', { p_attachment_id: attachment.id });
      if (result.error) {
        button.disabled = false;
        setMessage('Non è stato possibile eliminare l’allegato. Riprova.', true);
        return;
      }

      const { error: storageError } = await client.storage
        .from('familarea-attachments')
        .remove([attachment.storage_path]);
      setMessage(
        storageError
          ? 'Allegato eliminato, ma non è stato possibile rimuovere il file dallo spazio di archiviazione.'
          : 'Allegato eliminato.',
        Boolean(storageError)
      );
      await load();
    }

    function renderAttachment(attachment) {
      const row = document.createElement('div');
      row.className = 'deadline-attachment';
      const info = document.createElement('div');
      info.className = 'deadline-attachment-info';
      const name = document.createElement('strong');
      name.textContent = attachment.original_filename;
      const details = document.createElement('span');
      details.textContent = `${attachmentPreview.formatAttachmentType(attachment.mime_type)} · ${formatAttachmentSize(attachment.byte_size)}`;
      info.append(name, details);

      const actions = document.createElement('div');
      actions.className = 'deadline-attachment-actions';
      const open = document.createElement('button');
      open.type = 'button';
      open.className = 'secondary-button';
      open.textContent = 'Apri';
      open.onclick = () => openAttachment(attachment, open);
      const remove = document.createElement('button');
      remove.type = 'button';
      remove.className = 'secondary-button list-item-delete';
      remove.textContent = 'Elimina';
      remove.onclick = () => removeAttachment(attachment, remove);
      actions.append(open, remove);
      row.append(info, actions);
      return row;
    }

    async function load() {
      const { data, error } = await client.rpc('get_attachments', {
        p_target_type: 'deadline',
        p_target_id: deadlineId
      });
      if (error) {
        list.replaceChildren();
        empty.hidden = true;
        setMessage('Non è stato possibile caricare gli allegati. Riprova.', true);
        return;
      }
      const rows = data || [];
      list.replaceChildren(...rows.map(renderAttachment));
      empty.hidden = rows.length > 0;
    }

    input.onchange = async (event) => {
      if (uploadInProgress) return;
      const file = event.target.files[0];
      input.value = '';
      if (!file) return;
      if (!attachmentPreview.isSupportedMimeType(file.type)) {
        setMessage('Formato non supportato. Puoi allegare PDF, JPG, PNG o WebP.', true);
        return;
      }
      if (file.size > attachmentPreview.maxAttachmentBytes) {
        setMessage('Il file supera il limite massimo di 10 MB.', true);
        return;
      }

      setUploadInProgress(true);
      setMessage('Caricamento allegato…');
      try {
        const { data: account, error: accountError } = await client.rpc('get_current_account');
        if (accountError || !account?.account_id) throw accountError || new Error('Account non disponibile');

        const storageName = file.name.replace(/[\\/]/g, '-').trim() || 'allegato';
        const path = `attachments/${account.account_id}/deadline/${deadlineId}/${crypto.randomUUID()}-${storageName}`;
        const { error: uploadError } = await client.storage
          .from('familarea-attachments')
          .upload(path, file, { contentType: file.type, upsert: false });
        if (uploadError) throw uploadError;

        const { error: registrationError } = await client.rpc('register_attachment', {
          p_target_type: 'deadline',
          p_target_id: deadlineId,
          p_storage_path: path,
          p_original_filename: file.name,
          p_mime_type: file.type,
          p_byte_size: file.size
        });
        if (registrationError) {
          await client.storage.from('familarea-attachments').remove([path]);
          throw registrationError;
        }

        await load();
        setMessage('Allegato caricato.');
      } catch (error) {
        console.error('deadline attachment upload failed', error);
        setMessage('Non è stato possibile caricare l’allegato. Riprova.', true);
      } finally {
        setUploadInProgress(false);
      }
    };

    return { load };
  }

  window.FamilAreaDeadlineAttachments = { create };
}());
