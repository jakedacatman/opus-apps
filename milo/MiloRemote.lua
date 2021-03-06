_G.requireInjector(_ENV)

local Config = require('config')
local Event  = require('event')
local Sound  = require('sound')
local Socket = require('socket')
local sync   = require('sync').sync
local UI     = require('ui')
local Util   = require('util')

local colors = _G.colors
local device = _G.device
local fs     = _G.fs
local os     = _G.os
local string = _G.string

local SHIELD_SLOT  = 2
local STARTUP_FILE = 'usr/autorun/miloRemote.lua'

local config = Config.load('miloRemote', { displayMode = 0 })

local socket
local depositMode = {
  [ true  ] = { text = '\25',  textColor = colors.black, help = 'Deposit enabled' },
  [ false ] = { text = '\215', textColor = colors.red,   help = 'Deposit disabled' },
}

local displayModes = {
  [0] = { text = 'A', help = 'Showing all items' },
  [1] = { text = 'I', help = 'Showing inventory items' },
}

local page = UI.Page {
  menuBar = UI.MenuBar {
    y = 1, height = 1,
    buttons = {
      {
        text = 'Refresh',
        x = -12,
        event = 'refresh'
      },
      {
        text = '\206',
        x = -3,
        dropdown = {
          { text = 'Setup', event = 'setup' },
          UI.MenuBar.spacer,
          {
            text = 'Rescan storage',
            event = 'rescan',
            help = 'Rescan all inventories'
          },
        },
      },
    },
    infoBar = UI.StatusBar {
      x = 1, ex = -16,
      backgroundColor = colors.lightGray,
    },
  },
  grid = UI.Grid {
    y = 2, ey = -2,
    columns = {
      { heading = ' Qty', key = 'count'       , width = 4, justify = 'right' },
      { heading = 'Name', key = 'displayName' },
    },
    values = { },
    sortColumn = config.sortColumn or 'count',
    inverseSort = config.inverseSort,
    help = '^(s)tack, ^(a)ll'
  },
  statusBar = UI.Window {
    y = -1,
    filter = UI.TextEntry {
      x = 1, ex = -12,
      limit = 50,
      shadowText = 'filter',
      backgroundColor = colors.cyan,
      backgroundFocusColor = colors.cyan,
      accelerators = {
        [ 'enter' ] = 'eject',
      },
    },
    amount = UI.TextEntry {
      x = -11, ex = -7,
      limit = 3,
      shadowText = '1',
      shadowTextColor = colors.gray,
      backgroundColor = colors.black,
      backgroundFocusColor = colors.black,
      accelerators = {
        [ 'enter' ] = 'eject_specified',
      },
      help = 'Request amount',
    },
    depositToggle = UI.Button {
      x = -6,
      event = 'toggle_deposit',
      text = '\215',
    },
    display = UI.Button {
      x = -3,
      event = 'toggle_display',
      text = displayModes[config.displayMode].text,
      help = displayModes[config.displayMode].help,
    },
  },
  accelerators = {
    r = 'refresh',
    [ 'control-r' ] = 'refresh',
    [ 'control-e' ] = 'eject',
    [ 'control-s' ] = 'eject_stack',
    [ 'control-a' ] = 'eject_all',

    q = 'quit',
  },
  setup = UI.SlideOut {
    backgroundColor = colors.cyan,
    titleBar = UI.TitleBar {
      title = 'Remote Setup',
    },
    form = UI.Form {
      x = 2, ex = -2, y = 2, ey = -1,
      values = config,
      [1] = UI.TextEntry {
        formLabel = 'Server', formKey = 'server',
        help = 'ID for the server',
        shadowText = 'Milo server ID',
        limit = 6,
        validate = 'numeric',
        required = true,
      },
      [2] = UI.TextEntry {
        formLabel = 'Return Slot', formKey = 'slot',
        help = 'Use a slot for sending to storage',
        shadowText = 'Inventory slot #',
        limit = 5,
        validate = 'numeric',
        required = false,
      },
      [3] = UI.Checkbox {
        formLabel = 'Shield Slot', formKey = 'useShield',
        help = 'Or, use the shield slot for sending'
      },
      [4] = UI.Checkbox {
        formLabel = 'Run on startup', formKey = 'runOnStartup',
        help = 'Run this program on startup'
      },
      info = UI.TextArea {
        x = 1, ex = -1, y = 6, ey = -4,
        textColor = colors.yellow,
        marginLeft = 0,
        marginRight = 0,
        value = [[The Milo turtle must connect to a manipulator with a ]] ..
                [[bound introspection module. The neural interface must ]] ..
                [[also have an introspection module.]],
      },
    },
    statusBar = UI.StatusBar {
      backgroundColor = colors.cyan,
    },
  },
  items = { },
}

local function getPlayerName()
  local neural = device.neuralInterface

  if neural and neural.getName then
    return neural.getName()
  end
end

function page:setStatus(status)
  self.menuBar.infoBar:setStatus(status)
  self:sync()
end

function page:processMessages(s)
  Event.addRoutine(function()
    repeat
      local response = s:read()
      if not response then
        break
      end
      if response.type == 'received' then
        Sound.play('entity.item.pickup')
        local ritem = self.items[response.key]
        if ritem then
          ritem.count = response.count
          self.grid:draw()
          self:sync()
        end

      elseif response.type == 'list' then
        self.items = self:expandList(response.list)
        self:applyFilter()
        self.grid:draw()
        self.grid:sync()

      elseif response.type == 'transfer' then
        if response.count > 0 then
          Sound.play('entity.item.pickup')
          local item = self.items[response.key]
          if item then
            item.count = response.current
            self.grid:draw()
            self:sync()
          end
        end
        if response.craft then
          if response.craft > 0 then
            self:setStatus(response.craft .. ' crafting ...')
          elseif response.craft + response.count < response.requested then
            if response.craft + response.count == 0 then
              Sound.play('entity.villager.no')
            end
            self:setStatus((response.craft + response.count) .. ' available ...')
          end
        end
      end
      if response.msg then
        self:setStatus(response.msg)
      end
    until not s.connected

    s:close()
    s = nil
    self:setStatus('disconnected ...')
    Sound.play('entity.villager.no')
  end)
end

function page:sendRequest(data, statusMsg)
  if not config.server then
    self:setStatus('Invalid configuration')
    return
  end

  local player = getPlayerName()
  if not player then
    self:setStatus('Missing neural or introspection')
    return
  end

  local success
  sync(self, function()
    local msg
    for _ = 1, 2 do
      if not socket or not socket.connected then
        self:setStatus('connecting ...')
        socket, msg = Socket.connect(config.server, 4242)
        if socket then
          socket:write(player)
          local r = socket:read(2)
          if r and not r.msg then
            self:setStatus('connected ...')
            self:processMessages(socket)
          else
            msg = r and r.msg or 'Timed out'
            socket:close()
            socket = nil
          end
        end
      end
      if socket then
        if statusMsg then
          self:setStatus(statusMsg)
          Event.onTimeout(2, function()
            self:setStatus('')
          end)
        end
        if socket:write(data) then
          success = true
          return
        end
        socket:close()
        socket = nil
      end
    end
    self:setStatus(msg or 'Failed to connect')
  end)

  return success
end

function page.grid:getRowTextColor(row, selected)
  if row.is_craftable then
    return colors.yellow
  end
  if row.has_recipe then
    return colors.cyan
  end
  return UI.Grid:getRowTextColor(row, selected)
end

function page.grid:getDisplayValues(row)
  row = Util.shallowCopy(row)
  row.count = row.count > 0 and Util.toBytes(row.count) or ''
  return row
end

function page.grid:sortCompare(a, b)
  if self.sortColumn ~= 'displayName' then
    if a[self.sortColumn] == b[self.sortColumn] then
      if self.inverseSort then
        return a.displayName > b.displayName
      end
      return a.displayName < b.displayName
    end
    if a[self.sortColumn] == 0 then
      return self.inverseSort
    end
    if b[self.sortColumn] == 0 then
      return not self.inverseSort
    end
    return a[self.sortColumn] < b[self.sortColumn]
  end
  return UI.Grid.sortCompare(self, a, b)
end

function page.grid:eventHandler(event)
  if event.type == 'grid_sort' then
    config.sortColumn = event.sortColumn
    config.inverseSort = event.inverseSort
    Config.update('miloRemote', config)
  end
  return UI.Grid.eventHandler(self, event)
end

function page:transfer(item, count, msg)
  self:sendRequest({ request = 'transfer', item = item, count = count }, msg)
end

function page.setup:eventHandler(event)
  if event.type == 'focus_change' then
    self.statusBar:setStatus(event.focused.help)
  end
  return UI.SlideOut.eventHandler(self, event)
end

function page:eventHandler(event)
  if event.type == 'quit' then
    UI:exitPullEvents()

  elseif event.type == 'setup' then
    self.setup.form:setValues(config)
    self.setup:show()

  elseif event.type == 'toggle_deposit' then
    config.deposit = not config.deposit
    Util.merge(self.statusBar.depositToggle, depositMode[config.deposit])
    self.statusBar:draw()
    self:setStatus(depositMode[config.deposit].help)
    Config.update('miloRemote', config)

  elseif event.type == 'form_complete' then
    Config.update('miloRemote', config)
    self.setup:hide()
    self:refresh('list')
    self.grid:draw()
    self:setFocus(self.statusBar.filter)

    if config.runOnStartup then
      if not fs.exists(STARTUP_FILE) then
        Util.writeFile(STARTUP_FILE,
          [[os.sleep(1)
shell.openForegroundTab('packages/milo/MiloRemote')]])
      end
    elseif fs.exists(STARTUP_FILE) then
      fs.delete(STARTUP_FILE)
    end

  elseif event.type == 'form_cancel' then
    self.setup:hide()
    self:setFocus(self.statusBar.filter)

  elseif event.type == 'focus_change' then
    self.menuBar.infoBar:setStatus(event.focused.help)

  elseif event.type == 'eject' or event.type == 'grid_select' then
    local item = self.grid:getSelected()
    if item then
      self:transfer(item, 1, 'requesting 1 ...')
    end

  elseif event.type == 'eject_stack' then
    local item = self.grid:getSelected()
    if item then
      self:transfer(item, 'stack', 'requesting stack ...')
    end

  elseif event.type == 'eject_all' then
    local item = self.grid:getSelected()
    if item then
      self:transfer(item, 'all', 'requesting all ...')
    end

  elseif event.type == 'eject_specified' then
    local item = self.grid:getSelected()
    local count = tonumber(self.statusBar.amount.value)
    if item and count then
      self.statusBar.amount:reset()
      self:setFocus(self.statusBar.filter)
      self:transfer(item, count, 'requesting ' .. count .. ' ...')
    else
      Sound.play('entity.villager.no')
      self:setStatus('nope ...')
    end

  elseif event.type == 'rescan' then
    self:setFocus(self.statusBar.filter)
    self:refresh('scan')
    self.grid:draw()

  elseif event.type == 'refresh' then
    self:setFocus(self.statusBar.filter)
    self:refresh('list')
    self.grid:draw()

  elseif event.type == 'toggle_display' then
    config.displayMode = (config.displayMode + 1) % 2
    Util.merge(event.button, displayModes[config.displayMode])
    event.button:draw()
    self:applyFilter()
    self:setStatus(event.button.help)
    self.grid:draw()
    Config.update('miloRemote', config)

  elseif event.type == 'text_change' and event.element == self.statusBar.filter then
    self.filter = event.text
    if #self.filter == 0 then
      self.filter = nil
    end
    self:applyFilter()
    self.grid:draw()

  else
    UI.Page.eventHandler(self, event)
  end
  return true
end

function page:enable()
  self:setFocus(self.statusBar.filter)
  Util.merge(self.statusBar.depositToggle, depositMode[config.deposit])
  UI.Page.enable(self)
  if not config.server then
    self.setup:show()
  end
  Event.onTimeout(.1, function()
    self:refresh('list')
    self.grid:draw()
    self:sync()
  end)
end

local function splitKey(key)
  local t = Util.split(key, '(.-):')
  local item = { }
  if #t[#t] > 8 then
    item.nbtHash = table.remove(t)
  end
  item.damage = tonumber(table.remove(t))
  item.name = table.concat(t, ':')
  return item
end

function page:expandList(list)
  local t = { }
  for k,v in pairs(list) do
    local item = splitKey(k)
    item.has_recipe, item.count, item.displayName = v:match('(%d+):(%d+):(.+)')
    item.count = tonumber(item.count) or 0
    item.lname = item.displayName:lower()
    item.has_recipe = item.has_recipe == '1'
    t[k] = item
  end
  return t
end

function page:refresh(requestType)
  self:sendRequest({ request = requestType }, 'refreshing...')
end

function page:applyFilter()
  local function filterItems(t, filter, displayMode)
    if filter or displayMode > 0 then
      local r = { }
      if filter then
        filter = filter:lower()
      end
      for _,v in pairs(t) do
        if not filter or string.find(v.lname, filter, 1, true) then
          if filter or --displayMode == 0 or
            displayMode == 1 and v.count > 0 then
            table.insert(r, v)
          end
        end
      end
      return r
    end
    return t
  end
  local t = filterItems(self.items, self.filter, config.displayMode)
  self.grid:setValues(t)
end

Event.addRoutine(function()
  local lastTransfer
  while true do
    local sleepTime = 1.5
    if lastTransfer and os.clock() - lastTransfer < 3 then
      sleepTime = .25
    end

    os.sleep(socket and sleepTime or 5)
    if config.deposit then
      local neural = device.neuralInterface
      local inv = config.useShield and 'getEquipment' or 'getInventory'
      if not neural or not neural[inv] then
        _G._debug('missing Introspection module')
      elseif config.server and (config.useShield or config.slot) then
        local s, m = pcall(function()
          local method = neural[inv]
          local item = method and method().list()[config.useShield and SHIELD_SLOT or config.slot]
          if item then
            if page:sendRequest({
              request = 'deposit',
              slot = config.useShield and 'shield' or config.slot,
              count = item.count,
            }) then
              lastTransfer = os.clock()
            end
          end
        end)
        if not s and m then
          _debug(m)
        end
      end
    end
  end
end)

UI:setPage(page)
UI:pullEvents()

if socket then
  socket:close()
end
