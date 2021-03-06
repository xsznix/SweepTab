'use strict'

#
# Constants
#

# The maximum number of open tabs the user may have open before we close one.
const MAX_OPEN_TABS = 10

# The index of the "Restore" button in a tab closing notification.
const NOTIF_BUTTON_RESTORE = 0

# The index of the "Bookmark" button in a tab closing notification.
const NOTIF_BUTTON_BOOKMARK = 1

# The amount of leniency between the time we observed the tab closing and the
# time Chrome observed the tab closing we allow when searching for a closed tab
# in Chrome's recently closed sessions array.
const CLOSE_TIME_THRESHOLD = 2000_ms

# The minimum amount of time a tab has to be focused for it to be counted as
# actually focused.
const MIN_FOCUS_TIME = 1000_ms

# Print out debug logging.
const debug = true
!function log
  if debug
    switch &length
    | 1 => console.log &0
    | 2 => console.log &0, &1
    | 3 => console.log &0, &1, &2
    | otherwise => console.log 'Too many arguments in logging call!'

#
# Globals
#

# A lock to prevent openTabs from changing during asynchronous callbacks in
# closeTab.
openTabsListLock = new Lock!
openTabsListLock.acquire -> # Hold it until we initialize opneTabs.

# A sparse array of open tabs.
# Hash of:
# - [key = tab ID] (int)
# - lastFocusTime (timestamp)
# - timesFocused (int)
# - parentId (int: tab ID)
# - numChildTabs (int)
openTabs = []
openTabsCount = 0

# Timeout to update the lastFocusTime of a tab.
var focusTimeout

# An array of tabs that we have closed but have not yet received the onRemoved
# event for.
# Array of tab IDs.
closingTabs = []

# An array of notifications that are currently being displayed to the user.
# Hash of:
# - [key = notification ID] (string)
# - url (string)
# - title (string)
# - closeTime (timestamp)
openNotifications = {}


#
# Event and message listeners
#

# Try to close a tab when the user creates a new tab if the user has too many
# tabs open.
chrome\tabs .\onCreated .\addListener (tab) !->
  openTabsCount++
  log 'Tab ' + tab.id + ' created.'
  openTabs[tab.id] = createOpenTabsElem tab
  closeTab!


# Removes tab metadata from array. Updates parent's child tab count.
chrome\tabs .\onRemoved .\addListener (tabId) !->
  openTabsCount--
  parentId = openTabs[tabId]?.parentId
  if parentId?
    openTabs[parentId].numChildTabs--
  log 'Tab ' + tabId + ' closing.'
  # Since we are deleting information from `openTabs', we need to hold its lock.
  <-! openTabsListLock.acquire
  delete! openTabs[tabId]
  openTabsListLock.release!
  if closingTabs[tabId]
    delete! closingTabs[tabId]
    closeTab!


# Listen for when a tab is focused.
chrome\tabs .\onActivated .\addListener (activeInfo) !->
  clearTimeout focusTimeout
  tabId = activeInfo.tabId
  if openTabs[tabId]?
    focusTimeout := setTimeout (!->
      log 'Tab ' + tabId + ' focused.'
      openTabs[tabId]
        ..lastFocusTime = +new Date
        ..timesFocused++
      ), MIN_FOCUS_TIME
  else
    console.warn 'Tab not found in openTabs: ' + tabId
    tab <-! chrome\tabs .\get tabId
    openTabs[tabId] = (createOpenTabsElem tab) with timesFocused: 1


# Close notifications when clicked.
chrome\notifications .\onClicked .\addListener (notifId) !->
  notif = openNotifications[notifId]
  if notif? then chrome\notifications .\clear notifId


# Handle notification button action.
chrome\notifications .\onButtonClicked .\addListener (notifId, button) !->
  notif = openNotifications[notifId]
  return unless notif?
  switch button
  | NOTIF_BUTTON_RESTORE  => restoreTab notif
  | NOTIF_BUTTON_BOOKMARK => bookmarkTab notif
  chrome\notifications .\clear notifId


# Destroy notification metadata.
chrome\notifications .\onClosed .\addListener (notifId) !->
  delete! openNotifications[notifId]

#
# Helper functions
#

# Tries to find a tab to close, then closes it and notifies the user of the
# event.
!function closeTab
  <-! openTabsListLock.acquire
  if openTabsCount <= MAX_OPEN_TABS
    openTabsListLock.release!
    return

  # Find a tab to close.
  tabs <-! chrome\tabs .\query do
    pinned: false  # Pinned tabs are important, so ignore those.
    active: false  # Never close a tab the user has active.
    audible: false # Never close a tab that could be playing background music.
  toRemove = null
  toRemoveTime = +new Date
  removingNewtabPage = false
  for i, tab of tabs
    # A tab that has just been opened may not have yet been added to `openTabs'.
    if openTabs[tab.id] is undefined then continue
    # Always prefer closing new tabs.
    if 'chrome://newtab/' == tab.url or -1 != tab.url.indexOf 'www.google.com/_/chrome/newtab'
      toRemove = tab
      removingNewtabPage = true
      break
    # Otherwise, prefer closing the tab that was viewed the least recently
    else if openTabs[tab.id].lastFocusTime < toRemoveTime
      toRemove = tab
      toRemoveTime = openTabs[tab.id].lastFocusTime
  unless toRemove?
    openTabsListLock.release!
    return

  # Close it.
  closingTabs[toRemove.id] = true # This tells the `tabs.onRemoved' listener to
                                  # call closeTabs again once that tab has been
                                  # removed.
  <-! chrome\tabs .\remove toRemove.id
  # Retry if we failed to close the tab.
  if chrome\runtime [\lastError]?
    openTabsListLock.release!
    setTimeout closeTab, 0
    return
  # New tab pages aren't important enough for notifications.
  if removingNewtabPage
    openTabsListLock.release!
    return

  # Notify the user.
  iconUrl = toRemove.favIconUrl
  if not iconUrl? or 'http' != iconUrl.substring 0 4
    iconUrl = chrome\extension .\getURL 'assets/blank32.png'
  notifId <-! chrome\notifications .\create null do
    type: \basic
    iconUrl: iconUrl
    title: chrome\i18n .\getMessage \notif_closed_tab
    message: toRemove.title
    contextMessage: toRemove.url
    buttons:
      * title: chrome\i18n .\getMessage \notif_restore
      * title: chrome\i18n .\getMessage \notif_bookmark

  # Allow the notification to be acted upon later.
  openNotifications[notifId] =
    url: toRemove.url
    title: toRemove.title
    closeTime: +new Date

  openTabsListLock.release!


# Restores a tab. There doesn't actually exist a mapping between tab IDs and
# session IDs in Chrome, so we take an educated guess as to the session ID given
# the URL we knew the tab was last on and the time we closed the tab.
!function restoreTab notif
  # If restoring a session fails for any reason, simply open a new tab at the
  # last URL that the closed tab was on.
  !function backupRestore
    chrome\tabs .\create do
      url: notif.url

  toRestore = null
  function matchSession session
    session.tab? and
    session.tab.url == notif.url and
    notif.closeTime - CLOSE_TIME_THRESHOLD <
      session.lastModified * 1000 <
      notif.closeTime + CLOSE_TIME_THRESHOLD and
    toRestore := session

  sessions <-! chrome\sessions .\getRecentlyClosed
  if sessions.some matchSession
    <-! chrome\sessions .\restore toRestore.sessionId
    backupRestore! if chrome\runtime [\lastError]?
  else
    backupRestore!


# Adds the URL described by `notif' as a new bookmark in the "Saved by
# SweepTabs" bookmarks folder.
!function bookmarkTab notif
  # Unimplemented.
  debugger


# Creates a new element that can be inserted into `openTabs'. Updates the child
# tab count of parent.
function createOpenTabsElem tab
  if tab.openerTabId? and openTabs[tab.openerTabId]
    openTabs[tab.openerTabId].numChildTabs++
  do
    lastFocusTime: +new Date
    timesFocused: 0
    parentId: tab.openerTabId ? null
    numChildTabs: 0

#
# Debug exports
#
if debug
  window[\getOpenTabs] = ->
    openTabs: openTabs
    openTabsCount: openTabsCount
  window[\getClosingTabs] = -> closingTabs
  window[\getOpenNotifications] = -> openNotifications
  window[\setMaxOpenTabs] = (newMax) !-> MAX_OPEN_TABS = newMax

#
# Initialization
#

# Prepopulate openTabs array.
tabs <-! chrome\tabs .\query {}
openTabsCount := tabs.length
now = +new Date
tabs.forEach (tab) !->
  log 'Tab ' + tab.id + ' initialized.'
  openTabs[tab.id] = createOpenTabsElem tab
openTabsListLock.release!