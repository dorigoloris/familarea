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

  function validateFile(file) {
    if (!attachmentPreview.isSupportedMimeType(file.type)) return 'Formato non supportato. Puoi allegare PDF, JPG, PNG o WebP.';
    if (file.size > attachmentPreview.maxAttachmentBytes) return 'Il file supera il limite massimo di 10 MB.';
    return '';
  }

  async function uploadFile({ client, deadlineId, file }) {
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
      const validationMessage = validateFile(file);
      if (validationMessage) {
        setMessage(validationMessage, true);
        return;
      }

      setUploadInProgress(true);
      setMessage('Caricamento allegato…');
      try {
        await uploadFile({ client, deadlineId, file });

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

  function createDraft({ client, input, uploadControl, message, empty, list }) {
    const files = [];
    let uploadInProgress = false;

    function setMessage(text = '', isError = false) {
      message.textContent = text;
      message.classList.toggle('is-error', isError);
    }

    function render() {
      empty.hidden = files.length > 0;
      list.replaceChildren(...files.map((file) => {
        const row = document.createElement('div');
        row.className = 'deadline-attachment';
        const info = document.createElement('div');
        info.className = 'deadline-attachment-info';
        const name = document.createElement('strong');
        name.textContent = file.name;
        const details = document.createElement('span');
        details.textContent = `${attachmentPreview.formatAttachmentType(file.type)} · ${formatAttachmentSize(file.size)}`;
        info.append(name, details);
        const actions = document.createElement('div');
        actions.className = 'deadline-attachment-actions';
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'secondary-button list-item-delete';
        remove.textContent = 'Rimuovi';
        remove.disabled = uploadInProgress;
        remove.addEventListener('click', () => {
          const index = files.indexOf(file);
          if (index >= 0) files.splice(index, 1);
          render();
        });
        actions.append(remove);
        row.append(info, actions);
        return row;
      }));
    }

    input.onchange = (event) => {
      if (uploadInProgress) return;
      const selectedFiles = [...event.target.files];
      input.value = '';
      if (!selectedFiles.length) return;
      const validFiles = selectedFiles.filter((file) => !validateFile(file));
      const invalidFile = selectedFiles.find((file) => validateFile(file));
      files.push(...validFiles);
      render();
      setMessage(
        invalidFile
          ? `${validateFile(invalidFile)} Gli altri file validi restano selezionati.`
          : `${files.length} allegat${files.length === 1 ? 'o selezionato.' : 'i selezionati.'}`,
        Boolean(invalidFile)
      );
    };

    return {
      async uploadSelected(deadlineId) {
        if (uploadInProgress || files.length === 0) return { ok: true, failed: 0 };
        uploadInProgress = true;
        input.disabled = true;
        uploadControl.setAttribute('aria-disabled', 'true');
        const failedFiles = [];
        for (const file of files) {
          try {
            await uploadFile({ client, deadlineId, file });
          } catch (error) {
            console.error('deadline draft attachment upload failed', error);
            failedFiles.push(file);
          }
        }
        files.splice(0, files.length, ...failedFiles);
        uploadInProgress = false;
        input.disabled = false;
        uploadControl.setAttribute('aria-disabled', 'false');
        render();
        return { ok: failedFiles.length === 0, failed: failedFiles.length };
      }
    };
  }

  window.FamilAreaDeadlineAttachments = { create, createDraft };
}());
