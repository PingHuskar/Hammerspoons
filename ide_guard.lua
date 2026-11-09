-- ide_guard.lua
-- App guard: limits how many apps per group may run at a time.
--   Group "IDE":     only one IDE at a time
--   Group "Browser": up to 2 different browsers, but only 1 while a
--                    heavy IDE (see HEAVY_IDES) is running
-- If a group is already at its limit, any other app from the same group
-- that gets launched is killed automatically and an alert explains why.
--
-- Usage: save as ~/.hammerspoon/ide_guard.lua and add to init.lua:
--   require("ide_guard")
-- Then reload Hammerspoon config.

local M = {}

local FORCE_KILL_DELAY = 2 -- seconds before escalating to force kill

local BROWSER_LIMIT            = 2 -- browsers allowed when no heavy IDE is open
local BROWSER_LIMIT_HEAVY_IDE  = 1 -- browsers allowed while a heavy IDE is open

-- Heavy IDEs: while one of these runs, the browser limit drops to 1.
-- Any bundle ID starting with "com.jetbrains." also counts as heavy.
-- Electron editors (VS Code, Cursor, Windsurf, Antigravity, ...) are not heavy;
-- add their bundle IDs here if you want them to count.
local HEAVY_IDES = {
  ["com.apple.dt.Xcode"]        = true,
  ["com.google.android.studio"] = true,
}

-- Each group: ids = bundleID -> display name
--             names = lowercase exact app name -> display name (fallback)
local GROUPS = {
  {
    label = "IDE",
    singular = "IDE",
    plural = "IDEs",
    ids = {
      ["com.microsoft.VSCode"]           = "VS Code",
      ["com.microsoft.VSCodeInsiders"]   = "VS Code Insiders",
      ["com.vscodium"]                   = "VSCodium",
      ["com.todesktop.230313mzl4w4u92"]  = "Cursor",
      ["com.exafunction.windsurf"]       = "Windsurf",
      ["com.trae.app"]                   = "Trae",
      ["dev.zed.Zed"]                    = "Zed",
      ["com.apple.dt.Xcode"]             = "Xcode",
      ["com.google.android.studio"]      = "Android Studio",
      ["com.jetbrains.intellij"]         = "IntelliJ IDEA",
      ["com.jetbrains.intellij.ce"]      = "IntelliJ IDEA CE",
      ["com.jetbrains.pycharm"]          = "PyCharm",
      ["com.jetbrains.pycharm.ce"]       = "PyCharm CE",
      ["com.jetbrains.WebStorm"]         = "WebStorm",
      ["com.jetbrains.PhpStorm"]         = "PhpStorm",
      ["com.jetbrains.goland"]           = "GoLand",
      ["com.jetbrains.CLion"]            = "CLion",
      ["com.jetbrains.rubymine"]         = "RubyMine",
      ["com.jetbrains.rider"]            = "Rider",
      ["com.jetbrains.datagrip"]         = "DataGrip",
      ["com.panic.Nova"]                 = "Nova",
      ["com.anthropic.claudefordesktop"] = "Claude",
      -- Sublime Text intentionally excluded (treated as a note editor)
    },
    -- Verify names with: osascript -e 'id of app "Antigravity"'
    names = {
      ["claude"]          = "Claude",
      ["zcode"]           = "ZCode",
      ["z code"]          = "ZCode",
      ["antigravity"]     = "Antigravity",
      ["antigravity ide"] = "Antigravity IDE",
    },
  },
  {
    label = "Browser",
    singular = "browser",
    plural = "browsers",
    ids = {
      ["com.apple.Safari"]                   = "Safari",
      ["com.apple.SafariTechnologyPreview"]  = "Safari Technology Preview",
      ["com.google.Chrome"]                  = "Google Chrome",
      ["com.google.Chrome.beta"]             = "Chrome Beta",
      ["com.google.Chrome.dev"]              = "Chrome Dev",
      ["com.google.Chrome.canary"]           = "Chrome Canary",
      ["org.chromium.Chromium"]              = "Chromium",
      ["org.mozilla.firefox"]                = "Firefox",
      ["org.mozilla.firefoxdeveloperedition"] = "Firefox Developer Edition",
      ["com.microsoft.edgemac"]              = "Microsoft Edge",
      ["com.brave.Browser"]                  = "Brave",
      ["company.thebrowser.Browser"]         = "Arc",
      ["company.thebrowser.dia"]             = "Dia",
      ["com.operasoftware.Opera"]            = "Opera",
      ["com.vivaldi.Vivaldi"]                = "Vivaldi",
      ["com.kagi.kagimacOS"]                 = "Orion",
      ["app.zen-browser.zen"]                = "Zen",
      ["ai.perplexity.comet"]                = "Comet",
      ["com.duckduckgo.macos.browser"]       = "DuckDuckGo",
      ["org.torproject.torbrowser"]          = "Tor Browser",
    },
    names = {
      ["safari"]         = "Safari",
      ["google chrome"]  = "Google Chrome",
      ["firefox"]        = "Firefox",
      ["microsoft edge"] = "Microsoft Edge",
      ["brave browser"]  = "Brave",
      ["arc"]            = "Arc",
      ["dia"]            = "Dia",
      ["opera"]          = "Opera",
      ["vivaldi"]        = "Vivaldi",
      ["orion"]          = "Orion",
      ["zen"]            = "Zen",
      ["comet"]          = "Comet",
    },
  },
}

-- Returns the group an app belongs to (or nil), and its display name
local function classify(app)
  if not app then return nil end
  local bid = app:bundleID()
  local name = app:name()
  local lname = name and name:lower() or nil
  for _, g in ipairs(GROUPS) do
    if bid and g.ids[bid] then return g, g.ids[bid] end
    if lname and g.names[lname] then return g, g.names[lname] end
  end
  return nil
end

local BROWSER_GROUP
for _, g in ipairs(GROUPS) do
  if g.label == "Browser" then BROWSER_GROUP = g end
end

-- pids we already killed; ignored while they shut down
local dying = {}

local function displayName(app)
  local _, n = classify(app)
  return n or app:name() or "Unknown"
end

local function isHeavyIDE(app)
  local bid = app and app:bundleID()
  if not bid then return false end
  return HEAVY_IDES[bid] == true or bid:sub(1, 14) == "com.jetbrains."
end

-- Running apps in `group` (frontmost first), optionally excluding one app
local function runningInGroup(group, exclude)
  local front = hs.application.frontmostApplication()
  local fpid = front and front:pid()
  local xpid = exclude and exclude:pid()
  local list = {}
  for _, app in ipairs(hs.application.runningApplications()) do
    local pid = app:pid()
    if pid ~= xpid and not dying[pid] and classify(app) == group then
      if pid == fpid then table.insert(list, 1, app) else table.insert(list, app) end
    end
  end
  return list
end

local function runningHeavyIDE()
  for _, app in ipairs(hs.application.runningApplications()) do
    if not dying[app:pid()] and isHeavyIDE(app) then return app end
  end
  return nil
end

-- How many apps of `group` may run right now, plus the heavy IDE that
-- lowered the limit (if any)
local function limitFor(group)
  if group ~= BROWSER_GROUP then return 1, nil end
  local heavy = runningHeavyIDE()
  if heavy then return BROWSER_LIMIT_HEAVY_IDE, heavy end
  return BROWSER_LIMIT, nil
end

local function countLabel(group, n)
  if n == 1 then return "one " .. group.singular end
  return n .. " " .. group.plural
end

local function joinNames(apps)
  local names = {}
  for _, a in ipairs(apps) do table.insert(names, displayName(a)) end
  return table.concat(names, ", ")
end

local function notify(group, alertText, notifyText)
  hs.alert.show(alertText, { textSize = 18, atScreenEdge = 0 }, hs.screen.mainScreen(), 6)
  hs.notify.new({
    title = group.label .. " Guard",
    informativeText = notifyText,
    withdrawAfter = 10,
  }):send()
end

local function kill(app)
  local pid = app:pid()
  dying[pid] = true
  app:kill()
  hs.timer.doAfter(FORCE_KILL_DELAY, function()
    local still = hs.application.applicationForPID(pid)
    if still then still:kill9() end
    dying[pid] = nil
  end)
end

-- Kill `intruder` and explain which apps (`owners`) hold the slots
local function block(group, intruder, owners, limit, heavy)
  local iname, onames = displayName(intruder), joinNames(owners)
  local verb = #owners == 1 and "is" or "are"
  local rule
  if heavy then
    rule = string.format("Only %s allowed while %s is open.", countLabel(group, limit), displayName(heavy))
  else
    rule = string.format("Only %s allowed at a time.", countLabel(group, limit))
  end
  local fix = #owners == 1 and ("Close " .. onames .. " first.") or "Close one of them first."
  notify(group,
    string.format("🚫 %s blocked\nReason: %s %s already running.\n%s %s", iname, onames, verb, rule, fix),
    string.format("%s was closed because %s %s already running.", iname, onames, verb))
  kill(intruder)
end

-- Already-open browsers are never killed because a heavy IDE opened;
-- the user just gets asked to close the extras.
local function warnHeavy(heavy, browsers)
  local extra = #browsers - BROWSER_LIMIT_HEAVY_IDE
  notify(BROWSER_GROUP,
    string.format("⚠️ %s is a heavy IDE\nOnly %s allowed while it is open.\nOpen now: %s. Please close %d.",
      displayName(heavy), countLabel(BROWSER_GROUP, BROWSER_LIMIT_HEAVY_IDE), joinNames(browsers), extra),
    string.format("%s is open: please close %d browser(s) (%s).", displayName(heavy), extra, joinNames(browsers)))
end

local function check(app)
  if not app or dying[app:pid()] then return end
  local group = classify(app)
  if not group then return end

  local limit, heavy = limitFor(group)
  local others = runningInGroup(group, app)
  if #others >= limit then
    block(group, app, others, limit, heavy)
    return
  end

  if isHeavyIDE(app) then
    local browsers = runningInGroup(BROWSER_GROUP)
    if #browsers > BROWSER_LIMIT_HEAVY_IDE then warnHeavy(app, browsers) end
  end
end

M.watcher = hs.application.watcher.new(function(_, event, app)
  if event == hs.application.watcher.launched then
    -- small delay so the app is fully registered
    hs.timer.doAfter(0.3, function() check(app) end)
  end
end)
M.watcher:start()

-- On config load: if a group is over its limit, keep the frontmost app(s)
-- and close the rest. Groups run in order, so IDEs are settled before the
-- browser limit is worked out.
local function enforceOnLoad()
  for _, group in ipairs(GROUPS) do
    local apps = runningInGroup(group)
    local limit, heavy = limitFor(group)
    -- browsers are only killed above the normal limit, never for the heavy-IDE rule
    local hardLimit = (group == BROWSER_GROUP) and BROWSER_LIMIT or limit
    if #apps > hardLimit then
      local keep = {}
      for i = 1, hardLimit do keep[i] = apps[i] end
      for i = hardLimit + 1, #apps do block(group, apps[i], keep, hardLimit, nil) end
      apps = keep
    end
    if heavy and #apps > limit then warnHeavy(heavy, apps) end
  end
end
hs.timer.doAfter(1, enforceOnLoad)

hs.alert.show(string.format("App Guard active (1 IDE, %d browsers; %d with a heavy IDE)",
  BROWSER_LIMIT, BROWSER_LIMIT_HEAVY_IDE), 1.5)

return M
