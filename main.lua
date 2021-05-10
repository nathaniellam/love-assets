-- File for testing
local assets = require 'assets'
local r = 0
local dr = math.pi * 2

local asset_entries = {
  {
    'test-font',
    'assets/Kenney Future.ttf',
    draw = function(asset)
      love.graphics.print('This is Roboto', asset, 0, 20)
    end
  },
  {
    'test-image',
    'assets/pixel_style1.png',
    draw = function(asset)
      local h = asset:getHeight()
      love.graphics.draw(asset, 0, 120, 0, 80 / h, 80 / h)
    end
  },
  {
    'test-audio',
    'assets/you_win.ogg',
    nil,
    'stream',
    once = function(asset)
      asset:play()
    end,
    draw = function()
      love.graphics.print('You Win!', 0, 220)
    end
  },
  {
    'test-data',
    'assets/lorem_ipsum.txt',
    draw = function(asset)
      love.graphics.printf(asset:getString(), 0, 320, love.graphics.getWidth())
    end
  },
  {
    'test-custom',
    'assets/rectangle.txt',
    function(_path, data)
      local rect = {}
      local contents = data:getString()
      for k, v in string.gmatch(contents, '(%w+) = (%w+)') do
        rect[k] = tonumber(v)
      end
      return rect
    end,
    draw = function(asset)
      love.graphics.rectangle('fill', asset.x, asset.y, asset.width, asset.height)
    end
  }
}

function love.load()
  assets.init()
end

function love.update(dt)
  assets.update(dt)
  r = r + dr * dt

  for _, asset_entry in ipairs(asset_entries) do
    local status = assets.status(asset_entry[1])
    if status == 'loaded' then
      local asset = assets.get(asset_entry[1])
      if asset_entry.once then
        asset_entry.once(asset)
        asset_entry.once = nil
      end
    end
  end
end

function love.draw()
  love.graphics.arc('fill', love.graphics.getWidth() - 50, 50, 25, r, r + math.pi / 2)
  love.graphics.print('Click to load stuff', 300, 0)

  for i, asset_entry in ipairs(asset_entries) do
    local status = assets.status(asset_entry[1])
    love.graphics.print(asset_entry[1] .. ': ' .. status, 0, (i - 1) * 100)

    if status == 'loaded' then
      local asset = assets.get(asset_entry[1])
      if asset_entry.draw then
        asset_entry.draw(asset)
      end
    end
  end
end

local next_idx = 1
function love.mousepressed()
  if next_idx <= #asset_entries then
    assets.load(unpack(asset_entries[next_idx]))
    next_idx = next_idx + 1
  end
end

function love.quit()
  assets.shutdownWorkers()
end
