'use strict'

# The minimum amount of time a user has to leave a tab active for the tab to
# be counted as having been focused.
const MIN_FOCUSED_TIME = 2000_ms
var focusTimeout

onfocus = focusHandler
onblur = blurHandler

!function focusHandler
  focusTimeout := setTimeout sendFocusedMessage, MIN_FOCUSED_TIME

!function blurHandler
  clearTimeout focusTimeout

!function sendFocusedMessage
  messageSend \tab_focused, [+new Date]