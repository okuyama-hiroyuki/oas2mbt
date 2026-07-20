///|
/// Minimal indentation-based YAML subset sufficient to read OpenAPI 3.1
/// documents written in plain block style (no flow collections, no tabs,
/// no anchors/aliases). Not a general-purpose YAML parser.
pub(all) enum Yaml {
  YMap(Array[(String, Yaml)])
  YList(Array[Yaml])
  YStr(String)
}

///|
priv struct Line {
  indent : Int
  text : String
}

///|
fn indent_of(s : String) -> Int {
  let mut n = 0
  while n < s.length() && s[n] == ' ' {
    n += 1
  }
  n
}

///|
fn tokenize(src : String) -> Array[Line] {
  let lines = []
  for raw in src.split("\n") {
    let trimmed = raw.trim_end(chars=" \r").to_owned()
    let n = indent_of(trimmed)
    let content = trimmed.trim_start(chars=" ").to_owned()
    if content.length() == 0 {
      continue
    }
    lines.push({ indent: n, text: content })
  }
  lines
}

///|
fn unquote(s : String) -> String {
  let s = s.trim(chars=" ").to_owned()
  if s.length() >= 2 && s[0] == '\'' && s[s.length() - 1] == '\'' {
    s.substring(start=1, end=s.length() - 1).replace_all(old="''", new="'")
  } else {
    s
  }
}

///|
/// Splits a `key: value` line into (key, value). `value` is "" when the
/// line is just `key:`.
fn split_kv(text : String) -> (String, String) {
  // Find the first ": " or a trailing ":" that is not inside quotes.
  let mut in_quote = false
  let mut i = 0
  let n = text.length()
  let mut found = -1
  while i < n {
    let c = text[i]
    if c == '\'' {
      in_quote = not(in_quote)
    } else if not(in_quote) && c == ':' && (i + 1 == n || text[i + 1] == ' ') {
      found = i
      break
    }
    i += 1
  }
  if found < 0 {
    (text, "")
  } else {
    let key = text.substring(start=0, end=found).trim(chars=" ").to_owned()
    let value = if found + 1 >= n {
      ""
    } else {
      text.substring(start=found + 1, end=n).trim(chars=" ").to_owned()
    }
    (key, value)
  }
}

///|
/// Parses a run of lines that all sit at exactly `indent`, returning the
/// parsed value and the index of the first line not consumed.
fn parse_block(lines : Array[Line], start : Int, indent : Int) -> (Yaml, Int) {
  if start >= lines.length() || lines[start].indent != indent {
    return (YMap([]), start)
  }
  if lines[start].text.has_prefix("- ") || lines[start].text == "-" {
    parse_list(lines, start, indent)
  } else {
    parse_map(lines, start, indent)
  }
}

///|
fn parse_list(lines : Array[Line], start : Int, indent : Int) -> (Yaml, Int) {
  let items = []
  let mut i = start
  while i < lines.length() &&
        lines[i].indent == indent &&
        (lines[i].text.has_prefix("- ") || lines[i].text == "-") {
    let rest = if lines[i].text == "-" {
      ""
    } else {
      lines[i].text.substring(start=2, end=lines[i].text.length())
    }
    let item_indent = indent + 2
    if rest == "" {
      // Nested block belonging to this item, indented under the dash.
      let (value, next_i) = parse_block(lines, i + 1, item_indent)
      items.push(value)
      i = next_i
    } else {
      let mut j = i + 1
      while j < lines.length() && lines[j].indent >= item_indent {
        j += 1
      }
      let (_, colon_value) = split_kv(rest)
      if colon_value == "" && split_kv(rest).0 == rest && j == i + 1 {
        // Plain scalar item, e.g. `- x`.
        items.push(YStr(unquote(rest)))
      } else {
        // Synthesize a line for the item's own content, then keep consuming
        // any following lines that belong to the same item (indented under
        // the dash) as further map entries.
        let synth = { indent: item_indent, text: rest }
        let rebuilt = [synth]
        for k = i + 1; k < j; k = k + 1 {
          rebuilt.push(lines[k])
        }
        let (value, _) = parse_block(rebuilt, 0, item_indent)
        items.push(value)
      }
      i = j
    }
  }
  (YList(items), i)
}

///|
fn parse_map(lines : Array[Line], start : Int, indent : Int) -> (Yaml, Int) {
  let entries = []
  let mut i = start
  while i < lines.length() &&
        lines[i].indent == indent &&
        not(lines[i].text.has_prefix("- ")) &&
        lines[i].text != "-" {
    let (raw_key, raw_value) = split_kv(lines[i].text)
    let key = unquote(raw_key)
    if raw_value == "[]" {
      entries.push((key, YList([])))
      i += 1
    } else if raw_value == "{}" {
      entries.push((key, YMap([])))
      i += 1
    } else if raw_value == "" {
      let has_nested = i + 1 < lines.length() && lines[i + 1].indent > indent
      if has_nested {
        let (value, next_i) = parse_block(lines, i + 1, lines[i + 1].indent)
        entries.push((key, value))
        i = next_i
      } else {
        entries.push((key, YStr("")))
        i += 1
      }
    } else if raw_value.has_prefix("|") || raw_value.has_prefix(">") {
      // Block scalar: gather following more-indented lines as raw text.
      let body_indent = if i + 1 < lines.length() {
        lines[i + 1].indent
      } else {
        indent + 2
      }
      let parts = []
      let mut j = i + 1
      while j < lines.length() && lines[j].indent >= body_indent {
        let pad = String::make(lines[j].indent - body_indent, ' ')
        parts.push(pad + lines[j].text)
        j += 1
      }
      entries.push((key, YStr(parts.join("\n"))))
      i = j
    } else {
      entries.push((key, YStr(unquote(raw_value))))
      i += 1
    }
  }
  (YMap(entries), i)
}

///|
pub fn parse_yaml(src : String) -> Yaml {
  let lines = tokenize(src)
  if lines.length() == 0 {
    YMap([])
  } else {
    let (v, _) = parse_block(lines, 0, lines[0].indent)
    v
  }
}

///|
fn ymap_get(y : Yaml, key : String) -> Yaml? {
  match y {
    YMap(entries) => {
      for kv in entries {
        if kv.0 == key {
          return Some(kv.1)
        }
      }
      None
    }
    _ => None
  }
}

///|
/// Like `ymap_get`, but defaults to an empty map instead of `None`.
fn get(y : Yaml, key : String) -> Yaml {
  match ymap_get(y, key) {
    Some(v) => v
    None => YMap([])
  }
}

///|
fn ystr(y : Yaml) -> String {
  match y {
    YStr(s) => s
    _ => ""
  }
}

///|
fn ylist(y : Yaml) -> Array[Yaml] {
  match y {
    YList(l) => l
    _ => []
  }
}

///|
pub fn dump_yaml(y : Yaml) -> String {
  match y {
    YStr(s) => "YStr(\{s})"
    YList(items) => "[" + items.map(dump_yaml).join(", ") + "]"
    YMap(entries) =>
      "{" +
      entries.map(fn(kv) { kv.0 + ": " + dump_yaml(kv.1) }).join(", ") +
      "}"
  }
}
