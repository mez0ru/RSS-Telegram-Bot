# RSS Telegram Bot
 Inspired by my favorite RSS-to-Telegram-Bot by BoKKeR.
 

## What does it do?
 Conditionally notify users when new RSS is retrieved using telegram's bot api. \
 It's different from the original RSS-to-Telegram-Bot by BoKKeR, I made it so that it gives me updates when they contain keywords that I'm interested in.

## Why did you rewrite it?
 while the original python bot satisfies my needs, I was not able to run it on my router due to it being slow.
 Since Nim code is compiled, it's much more performant, which it did in my case.
 There's much to be done later, currently, it's for my personal use only.

### Dependencies:
Make sure to install these first:
```
nimble install telebot easy_sqlite3
```
Make sure to replace the const fields with your own fields in the main.nim source file.
