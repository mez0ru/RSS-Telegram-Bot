import tables, httpclient

import telebot/private/[types, keyboard, webhook, inputmedia, helpers]
export types, webhook, keyboard, inputmedia, helpers

proc setProxy*(b: Telebot, url: string, auth = "") {.inline.} =
  b.proxy = newProxy(url, auth)

proc newTeleBot*(token: string, serverUrl="https://api.telegram.org"): TeleBot =
  ## Init new Telegram Bot instance
  new(result)
  result.token = token
  result.serverUrl = serverUrl
  result.commandCallbacks = newTable[string, seq[CommandCallback]]()

include telebot/private/api
include telebot/private/events
