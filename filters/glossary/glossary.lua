--[[
Glossary filter.

Reads glossary.yml (at the project root) and, in HTML output:

  * marks the first use of each glossary term in every section (each level-2
    heading starts a new section) as a focusable "glossary-term" span. The
    span's aria-describedby points at the term's definition, and
    glossary.js shows that definition in a popup on hover, tap, or keyboard
    focus;
  * fills a Div with id "glossary" (see glossary.qmd) with every term and its
    definition, in alphabetical order.

Headings, links, code, math, citations and cross-references, images, raw
HTML (such as webexercises questions), page titles, and the "Check your
understanding" sections are never marked, nor is any Div or heading given the
class .no-glossary. Other formats (PDF)
are left unchanged, apart from the Glossary page.

Runs at the pre-ast stage (see _quarto.yml), so callout titles are still
ordinary headings and are skipped.
]]

local GLOSSARY_FILE = "glossary.yml"

-- Characters that may sit before or after a term without being part of it.
local LEADING = { "(", "[", '"', "\u{201C}", "\u{2018}", "'" }
local TRAILING = {
  ".", ",", ";", ":", "!", "?", ")", "]", '"', "\u{201D}", "\u{2019}", "'",
  "\u{2019}s", "'s",
}
table.sort(TRAILING, function(a, b) return #a > #b end)

-- Inline elements whose text is never marked.
local SKIP_INLINE = {
  Link = true, Image = true, Code = true, Math = true, RawInline = true,
  Cite = true, Note = true,
}

local entries = {}      -- every glossary entry, in file order
local lookup_ci = {}    -- lowercased phrase -> entry (or false for excludes)
local lookup_cs = {}    -- exact phrase -> entry
local max_words = 1
local used = {}         -- entries marked on this page, by id
local used_order = {}
local seen = {}         -- entry ids already marked in the current section

local function normalize(s)
  -- Smart quotes come from the Markdown reader; match them as straight ones.
  return (s:gsub("\u{2019}", "'"):gsub("\u{2018}", "'"))
end

local function slug(s)
  s = normalize(s):lower():gsub("[^%w]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  return s
end

local function html_escape(s)
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"))
end

local function word_count(s)
  local n = 0
  for _ in s:gmatch("%S+") do n = n + 1 end
  return n
end

local function project_path(file)
  local dir = quarto.project and quarto.project.directory
  if dir == nil or dir == "" then
    -- Fallback: two levels up from this script (filters/glossary/).
    dir = pandoc.path.directory(pandoc.path.directory(
      pandoc.path.directory(PANDOC_SCRIPT_FILE)))
  end
  return pandoc.path.join({ dir, file })
end

local function meta_blocks(value)
  if value == nil then return pandoc.Blocks({}) end
  local t = pandoc.utils.type(value)
  if t == "Inlines" then return pandoc.Blocks({ pandoc.Plain(value) }) end
  if t == "Blocks" then return value end
  return pandoc.Blocks({ pandoc.Plain(pandoc.Inlines(pandoc.utils.stringify(value))) })
end

local function meta_list(value)
  local out = {}
  if value == nil then return out end
  if pandoc.utils.type(value) == "List" then
    for _, v in ipairs(value) do table.insert(out, pandoc.utils.stringify(v)) end
  else
    table.insert(out, pandoc.utils.stringify(value))
  end
  return out
end

local function read_glossary(stem)
  local path = project_path(GLOSSARY_FILE)
  local f = io.open(path, "r")
  if not f then
    quarto.log.warning("glossary: could not open " .. path)
    return
  end
  local text = f:read("a")
  f:close()
  -- Let Pandoc parse the YAML, so definitions are read as Markdown.
  local meta = pandoc.read("---\n" .. text .. "\n---\n", "markdown").meta

  local function add(phrase, value, case_sensitive)
    local key = normalize(phrase)
    if case_sensitive then
      lookup_cs[key] = lookup_cs[key] or value
    else
      key = key:lower()
      if lookup_ci[key] == nil then lookup_ci[key] = value end
    end
    max_words = math.max(max_words, word_count(phrase))
  end

  for _, phrase in ipairs(meta_list(meta.exclude)) do add(phrase, false, false) end

  for _, item in ipairs(meta.terms or {}) do
    local term = pandoc.utils.stringify(item.term)
    local entry = {
      id = "gloss-" .. slug(term),
      term = term,
      definition = meta_blocks(item.definition),
      case_sensitive = item.case_sensitive == true,
      chapters = meta_list(item.chapters),
    }
    table.insert(entries, entry)

    local applies = #entry.chapters == 0
    for _, c in ipairs(entry.chapters) do
      if c == stem then applies = true end
    end
    if applies then
      add(term, entry, entry.case_sensitive)
      for _, alias in ipairs(meta_list(item.aliases)) do
        add(alias, entry, entry.case_sensitive)
      end
    end
  end
end

local function strip_affixes(word, list, at_start)
  local stripped = ""
  local changed = true
  while changed and #word > 0 do
    changed = false
    for _, p in ipairs(list) do
      if #word > #p then
        if at_start and word:sub(1, #p) == p then
          stripped = stripped .. p
          word = word:sub(#p + 1)
          changed = true
          break
        elseif not at_start and word:sub(-#p) == p then
          stripped = p .. stripped
          word = word:sub(1, -#p - 1)
          changed = true
          break
        end
      end
    end
  end
  return word, stripped
end

local function find_entry(phrase)
  local key = normalize(phrase)
  local hit = lookup_cs[key]
  if hit ~= nil then return hit end
  return lookup_ci[key:lower()]
end

-- Try to match a term starting at inlines[i] (a Str). Returns the entry (or
-- false for an exclude phrase), the index of the last element used, the
-- matched text, and any leading and trailing punctuation.
local function match_at(inlines, i)
  local words, idx = { inlines[i].text }, { i }
  local k = i
  while #words < max_words do
    local sep, nxt = inlines[k + 1], inlines[k + 2]
    if sep and (sep.t == "Space" or sep.t == "SoftBreak") and nxt and nxt.t == "Str" then
      table.insert(words, nxt.text)
      table.insert(idx, k + 2)
      k = k + 2
    else
      break
    end
  end

  for n = #words, 1, -1 do
    local first, prefix = strip_affixes(words[1], LEADING, true)
    local parts = { first }
    for m = 2, n do parts[m] = words[m] end
    local suffix = ""
    parts[n], suffix = strip_affixes(parts[n], TRAILING, false)
    local phrase = table.concat(parts, " ")
    local entry = find_entry(phrase)
    if entry ~= nil then
      return entry, idx[n], phrase, prefix, suffix
    end
  end
  return nil
end

local function mark(entry, text)
  if not used[entry.id] then
    used[entry.id] = true
    table.insert(used_order, entry)
  end
  return pandoc.RawInline("html", string.format(
    '<span class="glossary-term" tabindex="0" role="button" ' ..
    'aria-describedby="%s" data-term="%s">%s</span>',
    entry.id, html_escape(entry.term), html_escape(text)))
end

local process_inlines

process_inlines = function(inlines)
  local out = pandoc.Inlines({})
  local i = 1
  while i <= #inlines do
    local el = inlines[i]
    if el.t == "Str" then
      local entry, last, phrase, prefix, suffix = match_at(inlines, i)
      if entry and not seen[entry.id] then
        seen[entry.id] = true
        if prefix ~= "" then out:insert(pandoc.Str(prefix)) end
        out:insert(mark(entry, phrase))
        if suffix ~= "" then out:insert(pandoc.Str(suffix)) end
        i = last + 1
      elseif entry ~= nil then
        -- An exclude phrase, or a term already marked in this section: copy
        -- the matched words through unchanged so no shorter term inside them
        -- is marked instead.
        for m = i, last do out:insert(inlines[m]) end
        i = last + 1
      else
        out:insert(el)
        i = i + 1
      end
    else
      if not SKIP_INLINE[el.t] and el.content ~= nil
          and pandoc.utils.type(el.content) == "Inlines" then
        el.content = process_inlines(el.content)
      end
      out:insert(el)
      i = i + 1
    end
  end
  return out
end

local function glossary_list()
  local sorted = {}
  for _, e in ipairs(entries) do table.insert(sorted, e) end
  table.sort(sorted, function(a, b) return a.term:lower() < b.term:lower() end)
  local items = {}
  for _, e in ipairs(sorted) do
    local term = pandoc.Inlines({ pandoc.Span(pandoc.Inlines(e.term), { id = "term-" .. slug(e.term) }) })
    table.insert(items, { term, { e.definition } })
  end
  return pandoc.DefinitionList(items)
end

local is_html = false
local skip_section = false

-- Sections whose text is never marked: self-check questions, where a
-- definition could give an answer away. A heading can also opt out with
-- {.no-glossary}.
local SKIP_SECTIONS = { ["check your understanding"] = true }

local walker = {
  traverse = "topdown",

  -- Headings (including callout titles) are never marked.
  Header = function(el) return el, false end,

  Div = function(el)
    if el.identifier == "glossary" then
      el.content = pandoc.Blocks({ glossary_list() })
      return el, false
    end
    if el.classes:includes("no-glossary") then return el, false end
    -- Quarto adds hidden Divs (such as #quarto-meta-markdown) holding the
    -- page title and navigation text; leave those alone.
    if el.classes:includes("hidden") or el.identifier:match("^quarto%-") then
      return el, false
    end
    return el
  end,

  Inlines = function(inlines)
    if not is_html or skip_section then return inlines, false end
    return process_inlines(inlines), false
  end,
}

return {
  {
    Pandoc = function(doc)
      local stem = pandoc.path.split_extension(
        pandoc.path.filename(quarto.doc.input_file or ""))
      read_glossary(stem)
      is_html = quarto.doc.is_format("html")
      -- Quiz pages and the Glossary page itself get no popups.
      if stem:match("%-quiz$") or stem == "glossary" then
        is_html = false
      end

      -- Walk the body only (not the title or other metadata), one top-level
      -- block at a time, so that each level-2 heading starts a new section.
      local blocks = pandoc.Blocks({})
      for _, block in ipairs(doc.blocks) do
        if block.t == "Header" and block.level <= 2 then
          seen = {}
          skip_section = block.classes:includes("no-glossary")
            or SKIP_SECTIONS[pandoc.utils.stringify(block):lower()] == true
        end
        blocks:extend(pandoc.Blocks({ block }):walk(walker))
      end
      doc.blocks = blocks

      if is_html and #used_order > 0 then
        -- Attach the definitions used on this page, and the popup script.
        local html = { '<div class="glossary-defs" hidden>' }
        for _, e in ipairs(used_order) do
          local def = pandoc.write(pandoc.Pandoc(e.definition), "html")
          def = def:gsub("^%s*<p>", ""):gsub("</p>%s*$", "")
          table.insert(html, string.format('<span id="%s">%s</span>', e.id, def))
        end
        table.insert(html, "</div>")
        doc.blocks:insert(pandoc.RawBlock("html", table.concat(html, "\n")))

        quarto.doc.add_html_dependency({
          name = "glossary",
          version = "1.0.0",
          scripts = { "glossary.js" },
          stylesheets = { "glossary.css" },
        })
      end
      return doc, false
    end,
  },
}
