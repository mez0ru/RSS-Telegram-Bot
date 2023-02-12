# Package

version       = "0.2.0"
author        = "Hamzah Al-washali"
description   = "Telegram bot for rss notification"
license       = "MIT"
srcDir        = "src"
bin           = @["rss_notifier"]
backend       = "c"


# Dependencies

requires "nim >= 1.6.10"
requires "dotenv"
requires "easy_sqlite3"
