local assets = {
  _VERSION = 'assets v1.0.0',
  _DESCRIPTION = 'Asset management for love2D',
  _URL = 'https://github.com/nathaniellam/love-assets',
  _LICENSE = [[
    MIT License

    Copyright (c) 2021 Nathaniel Lam

    Permission is hereby granted, free of charge, to any person obtaining a copy
    of this software and associated documentation files (the "Software"), to deal
    in the Software without restriction, including without limitation the rights
    to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
    copies of the Software, and to permit persons to whom the Software is
    furnished to do so, subject to the following conditions:

    The above copyright notice and this permission notice shall be included in all
    copies or substantial portions of the Software.

    THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
    IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
    FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
    AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
    LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
    OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
    SOFTWARE.
  ]]
}

-----------------------------
-- Internal Helper Functions
-----------------------------

local function getExtension(path)
  local temp = love.filesystem.newFileData(path)
  local ext = temp:getExtension()
  temp:release()
  return ext
end

-----------------------------
-- Public Interface
-----------------------------

function assets.init(opts)
  if assets._initialized then
    error('assets has already been initialized')
  end

  if type(opts) == 'number' then
    opts = {num_workers = opts}
  elseif type(opts) == 'nil' then
    opts = {num_workers = 1}
  end

  local job_channel_name = opts.job_channel_name or assets.DEFAULT_JOB_CHANNEL_NAME
  local result_channel_name = opts.result_channel_name or assets.DEFAULT_RESULT_CHANNEL_NAME

  assets._initialized = true
  assets._result_cache = {}
  assets._workers = {}

  assets.job_channel = love.thread.getChannel(job_channel_name)
  assets.result_channel = love.thread.getChannel(result_channel_name)
  assets.num_workers = opts.num_workers
  for i = 1, assets.num_workers do
    assets._workers[i] = assets._createWorker()
  end
end

function assets.load(id, path, loader, ...)
  if not assets._result_cache[id] then
    local entry = {
      id = id,
      path = path,
      args = {...},
      status = 'loading',
      loader = loader
    }
    assets._result_cache[id] = entry

    local format = assets._getFormat(path, loader, ...)
    assets.job_channel:push({id = id, path = path, format = format})
  end
end

function assets.loadSync(id, path, loader, ...)
  local entry = {
    id = id,
    path = path,
    args = {...},
    status = 'loading',
    loader = loader
  }
  assets._result_cache[id] = entry
  assets._createAsset(entry, nil)
end

function assets.remove(id)
  local entry = assets._result_cache[id]
  if entry and entry.result then
    assets._result_cache[id] = nil
    return entry.result
  end
end

function assets.clear()
  assets._result_cache = {}
end

function assets.status(id)
  local entry = assets._result_cache[id]
  if entry then
    return entry.status
  end

  return 'not found', nil
end

function assets.get(id)
  local entry = assets._result_cache[id]
  if entry then
    if entry.status == 'loaded' then
      return entry.result
    else
      return nil, entry.err or 'Asset could not be loaded'
    end
  end

  return nil, 'Asset not found'
end

function assets.register(loader_key, loader_fn)
  local prev_loader = assets._loaders[loader_key]
  assets._loaders[loader_key] = loader_fn
  return prev_loader
end

function assets.unregister(loader_key)
  local prev_loader = assets._loaders[loader_key]
  assets._loaders[loader_key] = nil
  return prev_loader
end

function assets.update()
  while assets.result_channel:getCount() > 0 do
    local entry_update = assets.result_channel:pop()
    local entry = assets._result_cache[entry_update.id]
    if entry_update.err then
      entry.status = 'error'
      entry.err_message = entry_update.err
    elseif entry_update.data then
      assets._createAsset(entry, entry_update.data)
    end
  end
end

function assets.shutdownWorkers()
  -- Remove any existing jobs and send shutdown signal to all workers
  assets.job_channel:clear()
  for _ = 1, assets.num_workers do
    assets.job_channel:push(-1)
  end

  -- Wait for all workers to exit
  for _, worker in ipairs(assets._workers) do
    worker:wait()
  end
end

-- Constants

assets.DEFAULT_JOB_CHANNEL_NAME = 'assets_jobs'
assets.DEFAULT_RESULT_CHANNEL_NAME = 'assets_results'
assets.SUPPORTED_IMAGE_FORMATS = {'jpg', 'png', 'bmp'}
assets.SUPPORTED_AUDIO_FORMATS = {
  'wav',
  'mp3',
  'ogg',
  'oga',
  'ogv',
  '699',
  'amf',
  'ams',
  'dbm',
  'dmf',
  'dsm',
  'far',
  'it',
  'j2b',
  'mdl',
  'med',
  'mod',
  'mt2',
  'mtm',
  'okt',
  'psm',
  's3m',
  'stm',
  'ult',
  'umx',
  'xm',
  'abc',
  'mid',
  'pat',
  'flac'
}
assets.WORKER_SOURCE =
  [[
require 'love.image'
require 'love.sound'
require 'love.video'
local job_ch, result_ch = ...

while true do
  local job = job_ch:demand()
  if job == -1 then
    return
  else
    local data = nil
    if job.format == 'audio' then
      data = love.sound.newSoundData(job.path)
    elseif job.format == 'audio-stream' then
      data = love.sound.newDecoder(job.path)
    elseif job.format == 'image' then
      if love.image.isCompressed(job.path) then
        data = love.image.newCompressedData(job.path)
      else
        data = love.image.newImageData(job.path)
      end
    elseif job.format == 'video' then
      data = love.video.newVideoStream(job.path)
    else
      data = love.filesystem.newFileData(job.path)
    end
    result_ch:push({id = job.id, data = data})
  end
end
]]

-----------------------------
-- Private Interface
-----------------------------

function assets._createWorker()
  local worker_thread = love.thread.newThread(assets.WORKER_SOURCE)
  worker_thread:start(assets.job_channel, assets.result_channel)
  return worker_thread
end

function assets._createAsset(entry, data)
  local loader = entry.loader or getExtension(entry.path)
  if type(loader) ~= 'function' then
    loader = assets._loaders[loader] or assets._loaders.data
  end
  entry.result = loader(entry.path, data, unpack(entry.args or {}))
  entry.status = 'loaded'
end

function assets._getFormat(path, loader, ...)
  local ext = getExtension(path)
  local loader_fn = assets._loaders[loader or ext]
  if loader_fn == assets._loaders.data then
    return 'data'
  elseif loader_fn == assets._loaders.image then
    return 'image'
  elseif loader_fn == assets._loaders.audio then
    local type = ...
    if type == 'stream' then
      return 'audio-stream'
    end
    return 'audio'
  elseif loader_fn == assets._loaders.video then
    return 'video'
  end

  return 'data'
end

-- Built-in Loaders

assets._loaders = {}

-- Default loader, just returns FileData/ImageData/SoundData
assets._loaders.data = function(_path, data)
  return data
end

assets._loaders.image = function(path, data, ...)
  return love.graphics.newImage(data or path, ...)
end

for _, format in ipairs(assets.SUPPORTED_IMAGE_FORMATS) do
  assets._loaders[format] = assets._loaders.image
end

assets._loaders.audio = function(path, data, ...)
  return love.audio.newSource(data or path, ...)
end

for _, format in ipairs(assets.SUPPORTED_AUDIO_FORMATS) do
  assets._loaders[format] = assets._loaders.audio
end

assets._loaders.imagefont = function(path, data, ...)
  if data then
    local image_data = love.image.newImageData(data)
    return love.graphics.newImageFont(image_data, ...)
  else
    return love.graphics.newImageFont(path, ...)
  end
end

assets._loaders.font = function(path, data, ...)
  return love.graphics.newFont(data or path, ...)
end
assets._loaders.ttf = assets._loaders.font

assets._loaders.video = function(path, data, ...)
  return love.graphics.newVideo(data or path, ...)
end
assets._loaders.ogv = assets._loaders.video

setmetatable(
  assets,
  {
    __call = function(_, ...)
      return assets.load(...)
    end
  }
)

return assets
