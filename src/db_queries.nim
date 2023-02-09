import easy_sqlite3

proc CreateRSS*(name, link: string, etag = "") {.importdb: """
  INSERT INTO rss(name, link, etag) VALUES ($name, $link, $etag);
""".}

proc RemoveRSS*(name: string) {.importdb: """
  DELETE FROM rss WHERE name = $name;
""".}

iterator iterate_rss_full*(): tuple[id: int, name: string, link: string] {.importdb: """
  SELECT id, name, link FROM rss;
""".} = discard

iterator iterate_rss_names*(): tuple[id: int, name: string] {.importdb: """
  SELECT id, name FROM rss;
""".} = discard

iterator search_rss*(query: string): tuple[id: int, name: string] {.importdb: """
  SELECT id, name FROM rss WHERE name LIKE $query;
""".} = discard

proc add_url_condition*(url_condition: string): int {.importdb: """
  INSERT INTO urlCondition(condition) VALUES ($url_condition);
""".} = discard

proc remove_url_condition*(id: int) {.importdb: """
  DELETE FROM urlCondition WHERE id = $id;
""".} = discard

proc get_url_condition_id*(url_condition: string): tuple[id: int, condition: string] {.importdb: """
  SELECT id, condition FROM urlCondition WHERE condition LIKE $url_condition;
""".} = discard

iterator get_url_conditions*(): tuple[url_condition: string, condition: string] {.importdb: """
  SELECT urlCondition.condition, contentCondition.condition FROM urlCondition
  INNER JOIN contentCondition ON contentCondition.url_condition_id=urlCondition.id;
""".} = discard

proc add_content_condition*(url_condition_id: int, condition: string) {.importdb: """
  INSERT INTO contentCondition(condition, url_condition_id) VALUES ($condition, $url_condition_id);
""".} = discard

proc remove_content_condition*(condition: string) {.importdb: """
  DELETE FROM contentCondition WHERE condition = $condition;
""".} = discard

proc is_url_condition_exists*(url_condition: string): tuple[value: bool] {.importdb: """
  SELECT EXISTS(SELECT 1 FROM urlCondition WHERE condition=$url_condition);
""".} = discard

proc is_content_condition_exists*(url_condition_id: int): tuple[value: bool] {.importdb: """
  SELECT EXISTS(SELECT 1 FROM contentCondition WHERE url_condition_id=$url_condition_id);
""".} = discard

proc init_sqlite*() {.importdb: """
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
      condition text NOT NULL UNIQUE,
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