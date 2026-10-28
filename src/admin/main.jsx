import React from 'react'
import ReactDOM from 'react-dom/client'
import AdminApp from './AdminApp'
import { I18nProvider } from '../i18n'
import '../index.css'

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode>
    <I18nProvider fixedLang="th">
      <AdminApp />
    </I18nProvider>
  </React.StrictMode>,
)
