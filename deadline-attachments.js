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

  function validateFile(file, allowedMimeTypes = null) {
    if (!attachmentPreview.isSupportedMimeType(file.type) || (allowedMimeTypes && !allowedMimeTypes.includes(file.type))) return 'Formato non supportato. Puoi allegare PDF, JPG, PNG o WebP.';
    if (file.size > attachmentPreview.maxAttachmentBytes) return 'Il file supera il limite massimo di 10 MB.';
    return '';
  }

  async function uploadFile({ client, targetType = 'deadline', targetId, file }) {
    const { data: account, error: accountError } = await client.rpc('get_current_account');
    if (accountError || !account?.account_id) throw accountError || new Error('Account non disponibile');

    const storageName = file.name.replace(/[\\/]/g, '-').trim() || 'allegato';
    const path = `attachments/${account.account_id}/${targetType}/${targetId}/${crypto.randomUUID()}-${storageName}`;
    const { error: uploadError } = await client.storage
      .from('familarea-attachments')
      .upload(path, file, { contentType: file.type, upsert: false });
    if (uploadError) throw uploadError;

    const { error: registrationError } = await client.rpc('register_attachment', {
      p_target_type: targetType,
      p_target_id: targetId,
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

  function create({ client, deadlineId, targetId = deadlineId, targetType = 'deadline', canManage = true, input, uploadControl, message, empty, list, allowedMimeTypes = null, allowMultiple = false, multipleProgressLabel = 'fotografie', multipleCompleteLabel = 'Fotografie caricate', renderAttachmentActions = null, onAttachmentDeleted = null }) {
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

    async function removeAttachment(attachment, button, row) {
      const confirmed = await FamilAreaConfirm.confirm({
        variant: 'danger',
        title: 'Eliminare l’allegato?',
        message: `“${attachment.original_filename}” verrà eliminato definitivamente.`,
        confirmText: 'Elimina'
      });
      if (!confirmed) return;

      button.disabled = true;
      try {
        // The Storage policy verifies the attachment path while its metadata still exists.
        // Delete the object first, then remove the authorized metadata record.
        const { error: storageError } = await client.storage
          .from('familarea-attachments')
          .remove([attachment.storage_path]);
        if (storageError) throw storageError;

        const { error: deletionError } = await client.rpc('delete_attachment', { p_attachment_id: attachment.id });
        if (deletionError) throw deletionError;

        row.remove();
        if (typeof onAttachmentDeleted === 'function') {
          await onAttachmentDeleted(attachment);
        }
        setMessage('Allegato eliminato.');
        await load();
      } catch (error) {
        console.error('deadline attachment deletion failed', error);
        button.disabled = false;
        setMessage('Non è stato possibile eliminare l’allegato. Riprova.', true);
      }
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
      actions.append(open);
      const extraActions = typeof renderAttachmentActions === 'function'
        ? renderAttachmentActions(attachment)
        : null;
      if (Array.isArray(extraActions)) {
        actions.append(...extraActions.filter(Boolean));
      } else if (extraActions) {
        actions.append(extraActions);
      }
      if (canManage) {
        const remove = document.createElement('button');
        remove.type = 'button';
        remove.className = 'secondary-button list-item-delete';
        remove.textContent = 'Elimina';
        remove.onclick = () => removeAttachment(attachment, remove, row);
        actions.append(remove);
      }
      row.append(info, actions);
      return row;
    }

    async function load() {
      const { data, error } = await client.rpc('get_attachments', {
        p_target_type: targetType,
        p_target_id: targetId
      });
      if (error) {
        list.replaceChildren();
        empty.hidden = true;
        setMessage('Non è stato possibile caricare gli allegati. Riprova.', true);
        return;
      }
      const rows = (data || []).filter((attachment) => !allowedMimeTypes || allowedMimeTypes.includes(attachment.mime_type));
      list.replaceChildren(...rows.map(renderAttachment));
      empty.hidden = rows.length > 0;
    }

    input.onchange = async (event) => {
      if (!canManage) return;
      if (uploadInProgress) return;
      const selectedFiles = Array.from(event.target.files || []);
      input.value = '';
      if (!selectedFiles.length) return;

      const validFiles = [];
      const invalidFiles = [];
      selectedFiles.forEach((file) => {
        const validationMessage = validateFile(file, allowedMimeTypes);
        if (validationMessage) invalidFiles.push(`${file.name}: ${validationMessage}`);
        else validFiles.push(file);
      });
      if (!validFiles.length) {
        setMessage(invalidFiles.join(' '), true);
        return;
      }

      setUploadInProgress(true);
      const failedFiles = [];
      let uploadedCount = 0;
      for (const [index, file] of validFiles.entries()) {
        setMessage(allowMultiple && validFiles.length > 1
          ? `Caricamento ${multipleProgressLabel}: ${index + 1} di ${validFiles.length}`
          : 'Caricamento allegato…');
        try {
          await uploadFile({ client, targetType, targetId, file });
          uploadedCount += 1;
        } catch (error) {
          console.error('deadline attachment upload failed', error);
          failedFiles.push(file.name);
        }
      }
      try {
        await load();
        const rejectedSummary = invalidFiles.length ? ` ${invalidFiles.length} file non valid${invalidFiles.length === 1 ? 'o' : 'i'} ignorat${invalidFiles.length === 1 ? 'o' : 'i'}.` : '';
        const failedSummary = failedFiles.length ? ` Non caricat${failedFiles.length === 1 ? 'o' : 'i'}: ${failedFiles.join(', ')}.` : '';
        if (uploadedCount) {
          const uploadedSummary = allowMultiple && validFiles.length > 1
            ? `${multipleCompleteLabel}: ${uploadedCount} di ${validFiles.length}.`
            : 'Allegato caricato.';
          setMessage(`${uploadedSummary}${rejectedSummary}${failedSummary}`, Boolean(invalidFiles.length || failedFiles.length));
        } else {
          setMessage(`Nessun allegato caricato.${rejectedSummary}${failedSummary}`, true);
        }
      } catch (error) {
        console.error('deadline attachment list refresh failed', error);
        setMessage('Gli allegati sono stati elaborati, ma non è stato possibile aggiornare l’elenco. Riprova.', true);
      } finally {
        setUploadInProgress(false);
      }
    };

    if (!canManage) {
      input.disabled = true;
      uploadControl.hidden = true;
    }

    return { load };
  }

  function createDraft({ client, input, uploadControl, message, empty, list, targetType = 'deadline', allowedMimeTypes = null, multipleProgressLabel = 'allegati', multipleCompleteLabel = 'Allegati caricati' }) {
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
      const fileValidation = selectedFiles.map((file) => ({ file, error: validateFile(file, allowedMimeTypes) }));
      const validFiles = fileValidation.filter(({ error }) => !error).map(({ file }) => file);
      const invalidFiles = fileValidation.filter(({ error }) => error);
      files.push(...validFiles);
      render();
      setMessage(
        invalidFiles.length
          ? `${invalidFiles.map(({ file, error }) => `${file.name}: ${error}`).join(' ')} Gli altri file validi restano selezionati.`
          : `${files.length} allegat${files.length === 1 ? 'o selezionato.' : 'i selezionati.'}`,
        Boolean(invalidFiles.length)
      );
    };

    return {
      pendingCount() {
        return files.length;
      },
      async uploadSelected(targetId) {
        if (uploadInProgress || files.length === 0) return { ok: true, failed: 0 };
        uploadInProgress = true;
        input.disabled = true;
        uploadControl.setAttribute('aria-disabled', 'true');
        const failedFiles = [];
        let uploadedCount = 0;
        const filesToUpload = [...files];
        for (const [index, file] of filesToUpload.entries()) {
          setMessage(`Caricamento ${multipleProgressLabel}: ${index + 1} di ${filesToUpload.length}`);
          try {
            await uploadFile({ client, targetType, targetId, file });
            uploadedCount += 1;
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
        const failedSummary = failedFiles.length ? ` Non caricat${failedFiles.length === 1 ? 'o' : 'i'}: ${failedFiles.map((file) => file.name).join(', ')}.` : '';
        setMessage(
          failedFiles.length
            ? `${multipleCompleteLabel}: ${uploadedCount} di ${filesToUpload.length}.${failedSummary}`
            : `${multipleCompleteLabel}: ${uploadedCount} di ${filesToUpload.length}.`,
          Boolean(failedFiles.length)
        );
        return { ok: failedFiles.length === 0, failed: failedFiles.length, uploaded: uploadedCount };
      }
    };
  }

  window.FamilAreaDeadlineAttachments = { create, createDraft };
}());
