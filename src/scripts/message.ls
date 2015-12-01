'use strict'

# Handlers for messages of different types.
messageHandlers = {}

# Adds a listener for a certain type of message from the extension's background
# page.
!function messageListen type, callback
  messageHandlers[type] = callback

# Sends a message to the background tab.
!function messageSend type, args, cb
  msg =
    type: type
    args: args
  if cb?
    chrome.runtime.sendMessage null, msg, cb
  else
    chrome.runtime.sendMessage null, msg

# Sends a message to the a specific tab.
!function messageSendToTab tabId, type, args, cb
  msg =
    type: type
    args: args
  if cb?
    chrome.tabs.sendMessage tabId, msg, cb
  else
    chrome.tabs.sendMessage tabId, msg

# Responds to messages from the background tab to this tab.
chrome.runtime.onMessage.addListener (message, sender, sendResponse) !->
  # Get the message handler.
  handler = messageHandlers[message.type]
  return unless handler?

  # Handle the message.
  response = handler.apply message.args
  return unless response?

  # If applicable, send a response back.
  sendResponse response