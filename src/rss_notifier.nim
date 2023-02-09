from telebot/telebot import Telebot, newTeleBot, onCommand, sendMessage, repeat, poll
import asyncdispatch
import logging, strutils
from strformat import fmt
import httpClient
from streams import newStringStream
import xmlparser, xmltree
import tables, std/[times, lists, options]
from std/locks import Lock, withLock, initLock
import easy_sqlite3
import db_queries
import dotenv
import os

import CustomizedHttpClient

overload()

if not fileExists "data.db":
  echo "data.db doesn't seem to be found!, a new data.db will be created, press enter to continue."
  discard readLine(stdin)

var L = newConsoleLogger(fmtStr = "$levelname, [$time] ")
addHandler(L)

template hold(lock: Lock, body: untyped) =
  ## Wraps withLock in a gcsafe block.
  {.gcsafe.}:
    withLock lock:
      body

let API_KEY = strip getEnv("API_KEY")
const test_rss = "https://www.reddit.com/r/funny/new/.rss"

let chatId = parseBiggestInt(getEnv("CHAT_ID"))
let delay = parseInt(getEnv("DELAY"))
const DATE_FORMAT = "yyyy-MM-dd'T'HH:mm:sszzz"
const DISPLAY_DATE_FORMAT = "MMM dd, yyyy - h:mm tt"


type
  Entry = object
    title: string
    link: string
    published: Time
    didMatch: bool
    views: int

var lastLinks: Table[int, DoublyLinkedList[Entry]]
var predicates: Table[string, seq[string]]

var lastLinksLock,
    dbLock,
    predicatesLock,
  : Lock

lastLinksLock.initLock()
dbLock.initLock()
predicatesLock.initLock()
var db = easy_sqlite3.initDatabase("data.db");

proc contains(text: string, arr: openArray[string]): bool {.inline.} =
  for x in arr:
    if text.toLowerAscii().contains(x):
      return true
  return false

proc formAMessage(name, link, date: string; broadcasted = true): string {.inline.} =
  if broadcasted:
    fmt"Name: {name}{'\n'}Published: {date}{'\n'}{link}"
  else:
    fmt"Name: {name}{'\n'}Planned on: {date}{'\n'}{link}"

proc go(pool: AsyncHttpClientPool, url: string, i: int): Future[
    string] {.gcsafe, async.} =
  let client = await pool.dequeue()
  defer: pool.enqueue client

  while true:
    try:
      defer: client.close()
      return await client.getContent(url)
    except:
      echo "Can't download RSS, trying again..."
      await sleepAsync(2000)

proc runCommandOnFind(rss_link: string) =
  if parseInt(getEnv("RUN_ON_FIND")) == 0:
    return
  if execShellCmd(getEnv("COMMAND_ON_FIND").replace("%url", rss_link)) == 0:
    echo "Finished executing on find command successfully!"
  else:
    echo "Returned an error after executing on find command."

proc is_same(entries: var DoublyLinkedList[Entry], link: string, views: int): tuple[link, views: bool; entry: Option[Entry]] =
  var s_link, s_views = false
  for x in entries:
    if x.link == link:
      s_link = true
    else:
      continue
    if x.views > 0 or x.views == views or not x.didMatch:
      s_views = true
    else:
      entries.find(x).value.views = views
    return (s_link, s_views, some(x))
  return (s_link, s_views, none(Entry))

proc monitorRSS(b: Telebot, isRepeat: bool): Future[bool] {.gcsafe, async.} =
  echo fmt"isRepeat: {$isRepeat}"
  var toBeSentNotifications: seq[string]
  let pool = newAsyncHttpClientPool(4)
  var reqs: seq[Future[string]] = @[]
  var savedList: seq[tuple[id: int, name: string, rssLink: string]]
  hold dbLock:
    for id, name, rssLink in db.iterate_rss_full():
      savedList.add((id, name, rssLink))
      reqs.add go(pool, rssLink, id)
  echo "waiting for results..."
  let reports = await all(reqs)
  for i, (id, name, rssLink) in savedList:
    let root= parseXML(newStringStream(reports[i]))

    # Find feeds using the tag "entry", grab last 6.
    let entries = root.findAll("entry")[0..5]
    
    hold lastLinksLock:
      var isListNew = false

      if not lastLinks.hasKey(id):
        lastLinks[id] = initDoublyLinkedList[Entry]()
        isListNew = true
      
      var key: string
      for x in predicates.keys:
        if rssLink.contains x:
          key = x
          break

      var temp = initDoublyLinkedList[Entry]()
      
      for e in entries:
        let link = e.child("link").attr("href")
        let views = parseInt(e.child("media:group").child("media:community").child("media:statistics").attr("views"))
        
        let is_the_same = lastLinks[id].is_same(link, views)
        
        if is_the_same.link:
          if is_the_same.views:
            break
          else:
            runCommandOnFind(link)
            toBeSentNotifications.add formAMessage(name, link, format(is_the_same.entry.get().published, DISPLAY_DATE_FORMAT))
        else:
          let title = e.child("title").innerText
          let description = e.child("media:group").child("media:description").innerText
          let date = parseTime(e.child("published").innerText, DATE_FORMAT, utc())
          let didMatch = predicates[key] in title or predicates[key] in description
          if didMatch:
            let isBroadcasted = views > 0
            if isBroadcasted: # If stream is not yet airing don't bother with running the command
              runCommandOnFind(link)
            toBeSentNotifications.add formAMessage(name, link, format(date, DISPLAY_DATE_FORMAT), isBroadcasted)
          
          let newEntry = Entry(title: title, link: link, published: date, didMatch: didMatch, views: views)

          if isListNew:
            lastLinks[id].add newEntry
          else:
            temp.add newEntry
            lastLinks[id].remove lastLinks[id].tail

      if not isListNew:
        lastLinks[id].prepend temp
        
  if not isRepeat and toBeSentNotifications.len == 0:
    discard await b.sendMessage(chatId, "Nothing new 😖", parseMode = "markdown", disableNotification = false)
    return

  for x in toBeSentNotifications:
    discard await b.sendMessage(chatId, x, disableNotification = false)

  toBeSentNotifications.setLen(0)

  echo "Finished a test cycle"

proc formatConditions(t: Table): string =
  for k, v in t.pairs:
    result.add "{k} : {v.join(\", \")} \n".fmt

  if result.isEmptyOrWhitespace:
    return "Nothing is stored."

proc fill_predicates() =
  hold dbLock:
    hold predicatesLock:
      for url_condition, condition in db.get_url_conditions():
        if predicates.hasKey(url_condition):
          if not predicates[url_condition].contains condition:
            predicates[url_condition].add condition
        else:
          predicates[url_condition] = @[condition]

proc fill_predicates(u: string, c: openArray[string]) =
  hold predicatesLock:
    for condition in c:
      if predicates.hasKey(u):
        if not predicates[u].contains condition:
          predicates[u].add condition
      else:
        predicates[u] = @[condition]

proc remove_predicates(u: string, c: openArray[string]) =
  hold predicatesLock:
    for condition in c:
      if predicates.hasKey(u):
        let i = predicates[u].find condition
        if i != -1:
          predicates[u].del i

        if predicates[u].len == 0:
          predicates.del u

proc listRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  var noRecord = true
  hold dbLock:
    for id, name in db.iterate_rss_names:
      hold lastLinksLock:
        if lastLinks.hasKey(id):
          discard await b.sendMessage(chatId, formAMessage(name, lastLinks[
              id].head.value.link, format(lastLinks[id].head.value.published,
              DISPLAY_DATE_FORMAT), lastLinks[id].head.value.views > 0))
      noRecord = false
  if noRecord:
    discard await b.sendMessage(chatId, "List is empty :/")
  result = true

proc removeRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  if c.params.isEmptyOrWhitespace:
    discard await b.sendMessage(chatId, "No name provided, *nothing* is _done_.",
        parseMode = "markdown")
  elif c.params.contains ";":
    hold dbLock:
      db.RemoveRSS(strip(c.params))
    discard await b.sendMessage(chatId, fmt"Successfully removed {c.params}")
  else:
    let
      params = c.params.toLowerAscii().split ';'
      url_condition = params[0]
      conditions = params[1..^1]

    hold dbLock:
      db.transaction:
        let url_cond_id = case db.is_url_condition_exists(params[0]).value
          of true: db.get_url_condition_id(url_condition).id
          else: db.add_url_condition(url_condition)

        for x in conditions:
          db.remove_content_condition x
        if not db.is_content_condition_exists(url_cond_id).value:
          db.remove_url_condition url_cond_id


    remove_predicates(url_condition, conditions)
    discard await b.sendMessage(chatId, "Successfully removed {params[0]} with conditions:\n\"{conditions.join(\", \")}\".".fmt)
  result = true

proc addRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  if c.params.contains(" "):
    let rss = splitWhitespace c.params
    hold dbLock:
      db.CreateRSS(rss[0], rss[1])
    discard await b.sendMessage(chatId, fmt"Successfully added {rss[0]}")
  else:
    discard await b.sendMessage(chatId, "Wrong command, make sure you provide *BOTH* the _name_ and the _feed link_.\nExample:\n/add My-feed https://example.com/feed.xml",
        parseMode = "markdown")
  result = true

proc updateRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  discard await monitorRSS(b, false)

proc testRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  let client = newAsyncHttpClient()
  let rssContent = await client.getContent(test_rss)
  client.close()
  let root = parseXML(newStringStream(rssContent))

  # get the first "entry"
  let entry = root.child("entry")
  let entryLink = entry.child("link").attr("href")
  let entryTitle = entry.child("title").innerText
  discard await b.sendMessage(chatId, fmt"Title: {entryTitle}{'\n'}{entryLink}",
      disableNotification = false)

proc getRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  var noRecord = true
  let query = '%' & c.params & '%'
  hold dbLock:
    for id, name in db.search_rss(query):
      hold lastLinksLock:
        if lastLinks.hasKey(id):
          discard await b.sendMessage(chatId, formAMessage(name, lastLinks[
              id].head.value.link, format(lastLinks[id].head.value.published,
              DISPLAY_DATE_FORMAT), lastLinks[id].head.value.views > 0))
          for x in lastLinks[id].nodes:
            if x.prev != nil and x.value.didMatch:
              discard await b.sendMessage(chatId, formAMessage(name,
                  x.value.link, format(x.value.published, DISPLAY_DATE_FORMAT), x.value.views > 0))
          noRecord = false
  if noRecord:
    discard await b.sendMessage(chatId, "No records found, try again...")

proc conditionRSSCommand(b: Telebot, c: telebot.Command): Future[bool] {.gcsafe, async.} =
  let params = c.params.toLowerAscii().split(';')

  if params[0].isEmptyOrWhitespace:
    hold predicatesLock:
      discard await b.sendMessage(chatId, predicates.formatConditions(),
          disableNotification = true)
  elif params.len == 1:
    if params[0].contains ' ':
      discard await b.sendMessage(chatId,
          "Wrong format, make sure you use \";\" as a separator.",
          disableNotification = true)
    else:
      hold dbLock:
        if db.is_url_condition_exists(params[0]).value:
          let url_with_id = db.get_url_condition_id(params[0])
          hold predicatesLock:
            discard await b.sendMessage(chatId,
                "Conditions: {predicates[url_with_id.condition].join(\", \")}".fmt,
                disableNotification = true)
        else:
          discard await b.sendMessage(chatId, "Record doesn't exist.",
              disableNotification = true)
  else:
    let
      url_condition = params[0]
      conditions = params[1..^1]

    hold dbLock:
      let url_cond_id = case db.is_url_condition_exists(params[0]).value
        of true: db.get_url_condition_id(url_condition).id
        else: db.add_url_condition(url_condition)

      db.transaction:
        for x in conditions:
          db.add_content_condition url_cond_id, x

    fill_predicates(url_condition, conditions)
    discard await b.sendMessage(chatId, "Added {url_condition} with conditions:\n \"{conditions.join(\", \")}\" Successfully.".fmt,
        disableNotification = true)
  result = true

db.init_sqlite()

fill_predicates()

let bot = newTeleBot(API_KEY)

discard monitorRSS(bot, true)

bot.onCommand("list", listRSSCommand)
bot.onCommand("remove", removeRSSCommand)
bot.onCommand("add", addRSSCommand)
bot.onCommand("get", getRSSCommand)
bot.onCommand("condition", conditionRSSCommand)
bot.onCommand("update", updateRSSCommand)
bot.onCommand("test", testRSSCommand)
bot.repeat(delay, monitorRSS)

when not defined(release):
  bot.poll(timeout = 300)
else:
  while true:
    try:
      bot.poll(timeout = 300)
    except:
      echo "Telegram can't connect..."
      sleep(2000)
