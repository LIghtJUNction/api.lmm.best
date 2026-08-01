const { app, dialog } = require('electron')

const retirementMessage = [
  'The embedded Electron backend has been retired.',
  '',
  'LMM API now runs as the lmm-api-rs service and requires externally managed PostgreSQL and Valkey instances.',
  'Use the Rust release bundle or container deployment and open its web endpoint in a supported browser.',
  '',
  'This desktop shell will not start a legacy backend or create a local SQLite/Redis data store.',
].join('\n')

app.whenReady().then(async () => {
  await dialog.showMessageBox({
    type: 'warning',
    title: 'LMM API Desktop Retired',
    message: 'Embedded desktop service unavailable',
    detail: retirementMessage,
    buttons: ['Exit'],
    defaultId: 0,
    cancelId: 0,
  })
  app.quit()
})

app.on('window-all-closed', () => {
  app.quit()
})
