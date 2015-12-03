manifest_version: 2
name: '__MSG_ext_name__'
description: '__MSG_ext_desc__'
version: '1.0.0'
default_locale: \en

permissions:
  \unlimitedStorage
  \sessions
  \tabs
  \bookmarks
  \notifications
  'http://*/*'
  'https://*/*'

background:
  scripts:
    'scripts/synch.js'
    'scripts/background.js'