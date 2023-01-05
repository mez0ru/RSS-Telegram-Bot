from telebot import Telebot, newTeleBot, onCommand, sendMessage, repeat, poll, Command
import asyncdispatch
import logging, strutils
from strformat import fmt
import httpClient
from streams import newStringStream
import xmlparser, xmltree
import tables
from std/locks import Lock, withLock, initLock
import easy_sqlite3

var L = newConsoleLogger(fmtStr="$levelname, [$time] ")
addHandler(L)

template hold(lock: Lock, body: untyped) =
  ## Wraps withLock in a gcsafe block.
  {.gcsafe.}:
    withLock lock:
      body

const API_KEY = strip "YOUR API KEY"
const test_rss = "https://www.reddit.com/r/funny/new/.rss"

const chatId: int64 = "YOUR CHAT ID"
const delay: int64 = 28 * 60
const predicates = {"rss url": ["list of conditions"]}.toTable()

var lastLinks: Table[int64, seq[string]]

var lastLinksLock,
    dbLock,
    : Lock

lastLinksLock.initLock()
dbLock.initLock()

var db = initDatabase("data.db")

proc CreateRSS(name, link: string, etag = "") {.importdb: """
  INSERT INTO rss(name, link, etag) VALUES ($name, $link, $etag);
""".}

proc RemoveRSS(name: string) {.importdb: """
  DELETE FROM rss WHERE name = $name;
""".}

iterator iterate_rss_full(): tuple[id: int, name: string, link: string] {.importdb: """
  SELECT id, name, link FROM rss;
""".} = discard

iterator iterate_rss_names(): tuple[id: int, name: string] {.importdb: """
  SELECT id, name FROM rss;
""".} = discard

iterator search_rss(query: string): tuple[id: int, name: string] {.importdb: """
  SELECT id, name FROM rss WHERE name LIKE $query;
""".} = discard

proc init_sqlite() {.importdb: """
  CREATE TABLE IF NOT EXISTS rss(
    id INTEGER NOT NULL PRIMARY KEY,
    name text NOT NULL,
    link text NOT NULL,
    etag text,
    created_at timestamp NOT NULL DEFAULT current_timestamp,
    updated_at timestamp NOT NULL DEFAULT current_timestamp
  );

  CREATE TABLE IF NOT EXISTS urlCondition (
      id INTEGER NOT NULL PRIMARY KEY,
      condition text NOT NULL
  );
  
  CREATE TABLE IF NOT EXISTS contentCondition (
      id INTEGER NOT NULL PRIMARY KEY,
      condition text NOT NULL,
      url_condition_id INTEGER NOT NULL,
      FOREIGN KEY (url_condition_id) REFERENCES urlCondition(id) ON DELETE CASCADE
  );

  CREATE TRIGGER IF NOT EXISTS UpdateLastTime UPDATE OF name, link, etag ON rss
  BEGIN
    UPDATE rss SET updated_at=CURRENT_TIMESTAMP WHERE id=NEW.id;
  END;
""".}

proc contains(text: string, arr: openArray[string]): bool =
  for x in arr:
    if text.toLowerAscii().contains(x):
      return true
  result = false

proc formAMessage(name, link: string): string =
  fmt"RSS: {name}{'\n'}{link}"

proc monitorRSS(b: Telebot, isRepeat: bool): Future[bool] {.gcsafe, async.} =
  var toBeSentNotifications: seq[string]
  let client = newAsyncHttpClient()
  echo fmt"run with {$isRepeat}"
  hold dbLock:
    for id, name, rssLink in db.iterate_rss_full():
      # Get Xml content from rss link
      let rssContent = await client.getContent(rssLink)
      client.close()
      # Parse XML content
      let root= parseXML(newStringStream(rssContent))

      # Find feeds using the tag "entry", grab last 2s.
      let entries = root.findAll("entry")[0..1]

      let lastLink = entries[0].child("link").attr("href")
      
      hold lastLinksLock:
        if lastLinks.hasKey(id):
          if lastLinks[id].contains(lastLink):
            continue
          else:
            lastLinks[id].setLen(0)
            lastLinks[id].add(lastLink)
        else:
          lastLinks[id] = @[lastLink]
        
      var key: string
      for y in predicates.keys:
        if rssLink.contains(y):
          key = y
          break

      for i, y in entries[0..^1]:
        if predicates[key] in y.child("title").innerText or predicates[key] in y.child("media:group").child("media:description").innerText:
          if i != 0:
            let link = y.child("link").attr("href")
            toBeSentNotifications.add formAMessage(name, link)
            hold lastLinksLock:
              if not lastLinks[id].contains link:
                lastLinks[id].add(link)
          else:
            toBeSentNotifications.add formAMessage(name, lastLink)

  if not isRepeat and toBeSentNotifications.len == 0:
    discard await b.sendMessage(chatId, "Nothing new 😖", parseMode = "markdown", disableNotification = false)
    return

  for x in toBeSentNotifications:
    discard await b.sendMessage(chatId, x, disableNotification = false)

  toBeSentNotifications.setLen(0)

  echo "Finished a test cycle"

proc listRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  var noRecord = true
  hold dbLock:
    for id, name in db.iterate_rss_names:
      hold lastLinksLock:
        if lastLinks.hasKey(id) and lastLinks[id].len != 0:
          discard await b.sendMessage(chatId, fmt"Name: {name}{'\n'}Last RSS: {lastLinks[id][0]}")
      noRecord = false
  if not noRecord:
    discard await b.sendMessage(chatId, "List is empty :/")
  result = true

proc removeRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  if not c.params.isEmptyOrWhitespace:
    hold dbLock:
      db.RemoveRSS(strip(c.params))
    discard await b.sendMessage(chatId, fmt"Successfully removed {c.params}")
  else:
    discard await b.sendMessage(chatId, "No name provided, *nothing* is _done_.", parseMode = "markdown")
  result = true

proc addRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  if c.params.contains(" "):
    let rss = splitWhitespace c.params
    hold dbLock:
      db.CreateRSS(rss[0], rss[1])
    discard await b.sendMessage(chatId, fmt"Successfully added {rss[0]}")
  else:
    discard await b.sendMessage(chatId, "Wrong command, make sure you provide *BOTH* the _name_ and the _feed link_.\nExample:\n/add My-feed https://example.com/feed.xml", parseMode = "markdown")
  result = true

proc updateRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  discard await monitorRSS(b, false)

proc testRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  let client = newAsyncHttpClient()
  let rssContent = await client.getContent(test_rss)
  client.close()
  let root= parseXML(newStringStream(rssContent))

  # get the first "entry"
  let entry = root.child("entry")
  let entryLink = entry.child("link").attr("href")
  let entryTitle = entry.child("title").innerText
  discard await b.sendMessage(chatId, fmt"Title: {entryTitle}{'\n'}{entryLink}", disableNotification = false)

proc getRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  var noRecord = true
  let query = '%' & c.params & '%'
  hold dbLock:
    for id, name in db.search_rss(query):
      hold lastLinksLock:
        if lastLinks.hasKey(id):
          for link in lastLinks[id]:
            discard await b.sendMessage(chatId, fmt"Name: {name}{'\n'}Last RSS: {link}")
            noRecord = false
  if noRecord:
    discard await b.sendMessage(chatId, "No records found, try again...")


db.init_sqlite()

let bot = newTeleBot(API_KEY)

discard monitorRSS(bot, true)

bot.onCommand("list", listRSSCommand)
bot.onCommand("remove", removeRSSCommand)
bot.onCommand("add", addRSSCommand)
bot.onCommand("get", getRSSCommand)
bot.onCommand("update", updateRSSCommand)
bot.onCommand("test", testRSSCommand)
bot.repeat(delay, monitorRSS)
bot.poll(timeout=300)