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

local function contains(t, v)
  for _, u in ipairs(t) do
    if u == v then
      return true
    end
  end

  return false
end

-----------------------------
-- Public Interface
-----------------------------

assets._instance_num = 1
function assets.new(opts)
  if type(opts) == 'number' then
    opts = {num_workers = opts}
  elseif type(opts) == 'nil' then
    opts = {num_workers = 1}
  end
  local instance =
    setmetatable(
    {
      _result_cache = {},
      _workers = {},
      _job_queue = {}
    },
    {__index = assets}
  )

  instance.job_channel_name = instance.JOB_CHANNEL_PREFIX .. assets._instance_num
  instance.job_channel = love.thread.getChannel(instance.job_channel_name)
  instance.result_channel_name = instance.RESULT_CHANNEL_PREFIX .. assets._instance_num
  instance.result_channel = love.thread.getChannel(instance.result_channel_name)
  instance.num_workers = opts.num_workers
  for i = 1, instance.num_workers do
    instance._workers[i] = instance:_create_worker()
  end

  return instance
end

function assets:load(id, path, loader, ...)
  if not self._result_cache[id] then
    local entry = {
      id = id,
      path = path,
      args = {...},
      status = 'loading',
      progress = 0,
      loader = loader
    }
    self._result_cache[id] = entry

    -- If the asset is a streaming resource, then we can just create the object immediately since this will not block to
    -- read the file. Currently, videos and audio sources of type "stream" are the the only cases of this.
    local ext = getExtension(path)
    if loader == 'video' or ext == 'ogv' then
      self:_create_asset(entry, nil)
    elseif
      (loader == 'audio' or contains(self.SUPPORTED_AUDIO_FORMATS, ext)) and
        entry.args[1] == 'stream'
     then
      self:_create_asset(entry, nil)
    else
      -- Submit job for resources that need to be loaded
      self.job_channel:push({id = id, path = path})
    end
  end
end

function assets:load_sync(id, path, loader, ...)
  local entry = {
    id = id,
    path = path,
    args = {...},
    status = 'loading',
    progress = 0,
    loader = loader
  }
  self._result_cache[id] = entry
  self:_create_asset(entry, nil)
end

function assets:unload(id, can_release)
  local entry = self._result_cache[id]
  if entry and entry.result then
    if can_release then
      entry.result:release()
    end
    self._result_cache[id] = nil
  end
end

function assets:unload_all(can_release)
  if can_release then
    for _, entry in pairs(self._result_cache) do
      entry.result:release()
    end
  end

  self._result_cache = {}
end

function assets:status(id)
  local entry = self._result_cache[id]
  if entry then
    return entry.status, entry.progress
  end

  return 'not found', nil
end

function assets:get(id)
  local entry = self._result_cache[id]
  if entry then
    if entry.status == 'loaded' then
      return entry.result
    else
      return false, entry.err or 'Asset could not be loaded'
    end
  end

  return false, 'Asset not found'
end

function assets:update()
  while self.result_channel:getCount() > 0 do
    local entry_update = self.result_channel:pop()
    local entry = self._result_cache[entry_update.id]
    if entry_update.err then
      entry.status = 'error'
      entry.err_message = entry_update.err
    elseif entry_update.progress then
      entry.progress = entry_update.progress
    elseif entry_update.data then
      self:_create_asset(entry, entry_update.data)
    end
  end
end

function assets:shutdown_workers()
  -- Send shutdown signal to all workers
  for _, worker in ipairs(self._workers) do
    worker.side_channel:push(-1)
  end

  for _, _ in ipairs(self._workers) do
    self.job_channel:push(-1)
  end

  -- Wait for all workers to exit
  for _, worker in ipairs(self._workers) do
    worker.thread:wait()
  end
end

-- Constants

assets.JOB_CHANNEL_PREFIX = 'assets_jobs_'
assets.RESULT_CHANNEL_PREFIX = 'assets_results_'
assets.CHUNK_SIZE = 1048576 -- 1 MB in bytes
assets.WORK_THREAD_SOURCE =
  [[
  local job_ch, result_ch, side_ch, chunk_size = ...

  while true do
    local job = job_ch:demand()
    if job == -1 then
      -- Received exit command
      return
    else
      local file, err = love.filesystem.newFile(job.path, 'r')
      if err then
        result_ch:supply({id = job.id, err = err})
      else
        local total_bytes = file:getSize()
        local remaining_bytes = total_bytes
        local contents = ''
        while remaining_bytes > 0 do
          -- Check if shutdown has been initiated to cancel loading
          local value = side_ch:peek()
          if value == -1 then
            file:close()
            return
          end

          -- Read next chunk and append to result
          local read_bytes, num_read = file:read(chunk_size)
          contents = contents .. read_bytes
          remaining_bytes = remaining_bytes - num_read
          result_ch:supply({id = job.id, progress = (total_bytes - remaining_bytes) / total_bytes})
        end
        file:close()
        local data = love.filesystem.newFileData(contents, job.path)
        result_ch:supply({id = job.id, data = data})
      end
    end
  end
]]

-----------------------------
-- Private Interface
-----------------------------

function assets:_create_worker()
  local worker = {}
  local side_channel = love.thread.newChannel()
  worker.thread = love.thread.newThread(self.WORK_THREAD_SOURCE)
  worker.thread:start(self.job_channel, self.result_channel, side_channel, self.CHUNK_SIZE)
  worker.side_channel = side_channel
  return worker
end

function assets:_create_asset(entry, data)
  entry.progress = 1
  local loader = entry.loader or (data and data:getExtension()) or getExtension(entry.path)
  if type(loader) ~= 'function' then
    loader = self._loaders[loader] or self._loaders.data
  end
  entry.result = loader(entry.path, data, unpack(entry.args or {}))
  entry.status = 'loaded'
end

assets._loaders = {}

-- Default loader, just returns FileData
assets._loaders.data = function(_path, data)
  return data
end

assets._loaders.image = function(path, data, ...)
  return love.graphics.newImage(data or path, ...)
end

assets.SUPPORTED_IMAGE_FORMATS = {'jpg', 'png', 'bmp'}
for _, format in ipairs(assets.SUPPORTED_IMAGE_FORMATS) do
  assets._loaders[format] = assets._loaders.image
end

assets._loaders.audio = function(path, data, ...)
  return love.audio.newSource(data or path, ...)
end

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
    __call = function(_, opts)
      return assets.new(opts)
    end
  }
)

return assets
