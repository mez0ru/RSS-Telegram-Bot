import std/db_sqlite except open
import telebot, asyncdispatch, logging, options, strutils
import strformat
import httpClient
import streams, xmlparser, xmltree
import tables
import CustomizedHttpClient
import std/locks

var L = newConsoleLogger(fmtStr="$levelname, [$time] ")
addHandler(L)

template hold(lock: Lock, body: untyped) =
  ## Wraps withLock in a gcsafe block.
  {.gcsafe.}:
    withLock lock:
      body

let pool = newAsyncHttpClientPool(2)

const API_KEY = strip("YOUR API KEY")
const test_rss = "https://www.reddit.com/r/funny/new/.rss"

const chatId: int64 = 0 # Your chatID if you'd like to make it private for yourself only.
const delay = 1
const predicates = {"URL CONDITION": ["*contains this*", "*or maybe this*"]}.toTable()
var lastLinks: Table[int, seq[string]]
var toBeSentNotifications: seq[string]
var lastLinksLock,
    poolLock,
    toBeSentNotificationsLock
    : Lock
lastLinksLock.initLock()
poolLock.initLock()
toBeSentNotificationsLock.initLock()

let db = db_sqlite.open("data.db", "", "", "")

let bot = newTeleBot(API_KEY)


proc getAllRSS(): seq[Row] =
    return db.getAllRows(sql"SELECT * FROM rss")

proc CreateRSS(name, link: string, etag = ""): bool =
    db.tryExec(sql"INSERT INTO rss('name','link','etag') VALUES(?,?,?)", name, link, etag)

proc RemoveRSS(name: string): bool =
  db.tryExec(sql"DELETE FROM rss WHERE name = ?", name)

proc init_sqlite() =
    db.exec(sql"""
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
      END;""")

proc containsX(text: string, arr: openArray[string]): bool =
  for x in arr:
    if text.toLower().contains(x):
      return true
  result = false

proc formAMessage(name, title, link: string): string =
  fmt"RSS: {name}{'\n'}Title: {title}{'\n'}{link}"

proc monitorRSS(oneTime: bool, b: Telebot) {.gcsafe, async.} =
  while true:
    let allData = getAllRSS()
    for x in allData:
      # Get Xml content from rss link
      let id = parseInt(x[0])
      var rssContent: string
      hold poolLock:
        let client = await pool.dequeue()
        defer: pool.enqueue client
        rssContent = await client.getContent(x[2])
      # Parse XML content
      let root= parseXML(newStringStream(rssContent))

      # Find feeds using the tag "entry"
      let entries = root.findAll("entry")[0..1]

      # Get latest 5 feeds
      let lastEntry = entries[0].child("link").attr("href")
      
      hold lastLinksLock:
        if lastLinks.hasKey(id):
          if lastLinks[id].contains(lastEntry):
            continue
          else:
            lastLinks[id].setLen(0)
            lastLinks[id].add(lastEntry)
        else:
          lastLinks.add(id, @[lastEntry])
        
      var key: string
      for y in predicates.keys:
        if x[2].contains(y):
          key = y
          break
      # 2 entries is probably enough but you can go furthur
      for i, y in entries[0..^1]:
        if containsX(y.child("title").innerText, predicates[key]) or containsX(y.child("media:group").child("media:description").innerText, predicates[key]):
          let title = y.child("title").innerText
          if i != 0:
            let link = y.child("link").attr("href")
            hold toBeSentNotificationsLock:
              toBeSentNotifications.add(formAMessage(x[1], title, link))
            hold lastLinksLock:
              if not lastLinks[id].contains(link):
                lastLinks[id].add(link)
          else:
            hold toBeSentNotificationsLock:
              toBeSentNotifications.add(formAMessage(x[1], title, lastEntry))

    hold toBeSentNotificationsLock:
      if oneTime and toBeSentNotifications.len == 0:
        discard await b.sendMessage(chatId, "Nothing new 😖", parseMode = "markdown", disableNotification = false)
        return

      for x in toBeSentNotifications:
        discard await b.sendMessage(chatId, x, disableNotification = false)

      toBeSentNotifications.setLen(0)

    echo "Finished a test cycle"
    await sleepAsync(delay * 60 * 1000)

proc listRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  let data = getAllRSS()
  if data.len != 0:
    for row in data[0..^1]:
      let id = parseInt(row[0])
      hold lastLinksLock:
        if lastLinks.hasKey(id) and lastLinks[id].len != 0:
          discard await b.sendMessage(chatId, fmt"Name: {row[1]}{'\n'}Last RSS: {lastLinks[id][0]}")
  else:
    discard await b.sendMessage(chatId, "List is empty :/")
  result = true

proc removeRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  if not c.params.isEmptyOrWhitespace:
    if RemoveRSS(strip(c.params)):
      discard await b.sendMessage(chatId, fmt"Successfully removed {c.params}")
    else:
      discard await b.sendMessage(chatId, "Did not remove, database returned an error.")
  else:
    discard await b.sendMessage(chatId, "No name provided, *nothing* is _done_.", parseMode = "markdown")
  result = true

proc addRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  if c.params.contains(" "):
    let rss = c.params.split(' ')
    if CreateRSS(rss[0], rss[1]):
      discard await b.sendMessage(chatId, fmt"Successfully added {rss[0]}")
    else:
      discard await b.sendMessage(chatId, "Did not remove, database returned an error.")
  else:
    discard await b.sendMessage(chatId, "Wrong command, make sure you provide *BOTH* the _name_ and the _feed link_.\nExample:\n/add My-feed https://example.com/feed.xml", parseMode = "markdown")
  result = true

proc updateRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe,async.} =
  await monitorRSS(true, b)

proc testRSSCommand(b: Telebot, c: Command): Future[bool] {.gcsafe, async.} =
  var rssContent: string
  hold poolLock:
    let client = await pool.dequeue()
    defer: pool.enqueue client
    rssContent = await client.getContent(test_rss)
  
  let root= parseXML(newStringStream(rssContent))

  # get the first "entry"
  let entry = root.child("entry")
  let entryLink = entry.child("link").attr("href")
  let entryTitle = entry.child("title").innerText
  discard await b.sendMessage(chatId, fmt"Title: {entryTitle}{'\n'}{entryLink}", disableNotification = false)


init_sqlite()



bot.onCommand("list", listRSSCommand)
bot.onCommand("remove", removeRSSCommand)
bot.onCommand("add", addRSSCommand)
bot.onCommand("update", updateRSSCommand)
bot.onCommand("test", testRSSCommand)
discard monitorRSS(false, bot)
bot.poll(timeout=300)