from telebot import Telebot, newTeleBot, onCommand, sendMessage, repeat, poll, Command
import asyncdispatch
import logging, strutils
from strformat import fmt
import httpClient
from streams import newStringStream
import xmlparser, xmltree
import tables, std/[os, times, lists]
from std/locks import Lock, withLock, initLock
import easy_sqlite3
import CustomizedHttpClient

var L = newConsoleLogger(fmtStr="$levelname, [$time] ")
addHandler(L)

template hold(lock: Lock, body: untyped) =
  ## Wraps withLock in a gcsafe block.
  {.gcsafe.}:
    withLock lock:
      body

const API_KEY = strip "YOUR API KEY"
const test_rss = "https://www.reddit.com/r/funny/new/.rss"

const chatId: int64 = "Your chat id"
const delay: int64 = 29 * 60
const DATE_FORMAT = "yyyy-MM-dd'T'HH:mm:sszzz"
const DISPLAY_DATE_FORMAT = "MMM dd, yyyy - h:mm tt"
const predicates = {"rss url": ["conditions"]}.toTable()

type
  Entry = object
    title: string
    link: string
    published: Time
    didMatch: bool

var lastLinks: Table[int, DoublyLinkedList[Entry]]

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
  return false

proc contains_link(entries: DoublyLinkedList[Entry], link: string): bool =
  for x in entries:
    if x.link == link:
      return true
  return false

proc formAMessage(name, link, date: string): string =
  fmt"Name: {name}{'\n'}Published: {date}{'\n'}{link}"

proc go(pool: AsyncHttpClientPool, url: string, i: int64): Future[string] {.async.} =
  let client = await pool.dequeue()
  defer: pool.enqueue client

  while true:
    try:
      defer: client.close()
      return await client.getContent(url)
    except OSError:
      echo "Can't download RSS, trying again..."
      await sleepAsync(2000)

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
  var i = 0
  for (id, name, rssLink) in savedList:
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
        
        if lastLinks[id].contains_link link:
          break

        let title = e.child("title").innerText
        let description = e.child("media:group").child("media:description").innerText
        let date = parseTime(e.child("published").innerText, DATE_FORMAT, utc())
        var didMatch = false
        if predicates[key] in title or predicates[key] in description:
          didMatch = true
          toBeSentNotifications.add formAMessage(name, link, format(date, DISPLAY_DATE_FORMAT))
        
        let newEntry = Entry(title: title, link: link, published: date, didMatch: didMatch)

        if isListNew:
          lastLinks[id].add newEntry
        else:
          temp.add newEntry
          lastLinks[id].remove lastLinks[id].tail

      if not isListNew:
        lastLinks[id].prepend temp
    inc i
        
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
        if lastLinks.hasKey(id):
          discard await b.sendMessage(chatId, formAMessage(name, lastLinks[id].head.value.link, format(lastLinks[id].head.value.published, DISPLAY_DATE_FORMAT)))
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
          discard await b.sendMessage(chatId, formAMessage(name, lastLinks[id].head.value.link, format(lastLinks[id].head.value.published, DISPLAY_DATE_FORMAT)))
          echo $lastLinks[id].head.value.didMatch
          for x in lastLinks[id].nodes:
            if x.prev != nil and x.value.didMatch:
              echo "matched"
              discard await b.sendMessage(chatId, formAMessage(name, x.value.link, format(x.value.published, DISPLAY_DATE_FORMAT)))
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
while true:
  try:
    bot.poll(timeout=300)
  except OSError:
    echo "Telegram can't connect..."
    sleep(2000)