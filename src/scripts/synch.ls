'use strict'

# A simple lock, because callback hell necessitates some synchronization.
class Lock
  ->
    @held = false
    @waiters = []

  acquire: (callback) !->
    if @held
      @waiters.push callback
    else
      @held = true
      callback!

  release: !->
    if @waiters.length
      setTimeout @waiters.shift!, 0
    else
      @held = false

# Exports.
window['Lock'] = Lock