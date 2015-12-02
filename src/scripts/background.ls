'use strict'

#
# Constants
#

# The maximum number of open tabs the user may have open before we close one.
const MAX_OPEN_TABS = 5

# The index of the "Restore" button in a tab closing notification.
const NOTIF_BUTTON_RESTORE = 0

# The index of the "Bookmark" button in a tab closing notification.
const NOTIF_BUTTON_BOOKMARK = 1

# The amount of leniency between the time we observed the tab closing and the
# time Chrome observed the tab closing we allow when searching for a closed tab
# in Chrome's recently closed sessions array.
const CLOSE_TIME_THRESHOLD = 2000_ms


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
openTabs = []
openTabsCount = 0

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
chrome.tabs.onCreated.addListener !->
  openTabsCount++
  closeTab!

# When a tab with a "chrome://" URL is opened, don't wait for our content script
# to send us a message, since we can't run on "chrome://" URLs.
chrome.tabs.onUpdated.addListener (tabId, changeInfo, tab) !->
  if 0 == changeInfo.url?.indexOf 'chrome://'
    unless openTabs[tabId]?
      openTabs[tabId] =
        lastFocusTime: +new Date


# Removes tab metadata from array.
chrome.tabs.onRemoved.addListener (tabId) !->
  openTabsCount--
  # Since we are deleting information from `openTabs', we need to hold its lock.
  <-! openTabsListLock.acquire
  delete! openTabs[tabId]
  openTabsListLock.release!
  if closingTabs[tabId]
    delete! closingTabs[tabId]
    closeTab!


# Close notifications when clicked.
chrome.notifications.onClicked.addListener (notifId) !->
  notif = openNotifications[notifId]
  if notif? then chrome.notifications.clear notifId


# Handle notification button action.
chrome.notifications.onButtonClicked.addListener (notifId, button) !->
  notif = openNotifications[notifId]
  return unless notif?
  switch button
  | NOTIF_BUTTON_RESTORE  => restoreTab notif
  | NOTIF_BUTTON_BOOKMARK => bookmarkTab notif
  chrome.notifications.clear notifId


# Destroy notification metadata.
chrome.notifications.onClosed.addListener (notifId) !->
  delete! openNotifications[notifId]


# Listen for when a tab is focused.
messageListen \tab_focused (sender, timestamp) !->
  return unless sender?.tab?.id?
  if openTabs[sender.tab.id]?
    openTabs[sender.tab.id].lastFocusTime = timestamp
  else
    openTabs[sender.tab.id] =
      lastFocusTime: timestamp

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
  tabs <-! chrome.tabs.query do
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
    if tab.url == 'chrome://newtab/' or tab.url.indexOf('www.google.com/_/chrome/newtab') != -1
      toRemove = tab
      removingNewtabPage = true
      break;
    # Otherwise, prefer closing the tab that was viewed last
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
  <-! chrome.tabs.remove toRemove.id
  # Retry if we failed to close the tab.
  if chrome.runtime.lastError?
    openTabsListLock.release!
    setTimeout closeTab, 0
    return
  # New tab pages aren't important enough for notifications.
  if removingNewtabPage
    openTabsListLock.release!
    return

  # Notify the user.
  iconUrl = toRemove.favIconUrl
  if 'http' != iconUrl.substring 0 4
    iconUrl = chrome.extension.getURL 'assets/blank32.png'
  notifId <-! chrome.notifications.create null do
    type: \basic
    iconUrl: iconUrl
    title: chrome.i18n.getMessage \notif_closed_tab
    message: toRemove.title
    contextMessage: toRemove.url
    buttons:
      * title: chrome.i18n.getMessage \notif_restore
      * title: chrome.i18n.getMessage \notif_bookmark

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
  sessions <-! chrome.sessions.getRecentlyClosed
  toRestore = null
  return unless sessions.some (session) ->
    session.tab? and
    session.tab.url == notif.url and
    notif.closeTime - CLOSE_TIME_THRESHOLD < session.lastModified * 1000 < notif.closeTime + CLOSE_TIME_THRESHOLD and
    toRestore := session

  <-! chrome.sessions.restore toRestore.sessionId


# Adds the URL described by `notif' as a new bookmark in the "Saved by
# SweepTabs" bookmarks folder.
!function bookmarkTab notif
  # Unimplemented.
  debugger


#
# Initialization
#

# Prepopulate openTabs array.
tabs <-! chrome.tabs.query {}
openTabsCount := tabs.length
now = +new Date
tabs.forEach (tab) !->
  openTabs[tab.id] =
    lastFocusTime: now
openTabsListLock.release!