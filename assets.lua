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

  assets._initialized = true
  assets._result_cache = {}
  assets._workers = {}
  assets._job_queue = {}
  assets._lock = nil

  assets.job_channel = love.thread.newChannel()
  assets.result_channel = love.thread.newChannel()
  assets.lock_channel = love.thread.newChannel()
  assets.num_workers = opts.num_workers
  for i = 1, assets.num_workers do
    assets._workers[i] = assets._createWorker(i)
  end

  for k, v in pairs(assets._loaders) do
    assets.loader(k, v)
  end
end

function assets.load(id, path, loader_id, finalizer_id)
  if assets._result_cache[id] then
    error('Attempted to load "' .. id .. '" without removing it first')
  end

  finalizer_id = finalizer_id or loader_id
  local loader, loader_type, loader_args =
    assets._extractLoader(loader_id or getExtension(path) or 'default')
  local finalizer, finalizer_type, finalizer_args =
    assets._extractFinalizer(finalizer_id or getExtension(path) or 'default')
  local entry = {
    id = id,
    path = path,
    status = 'loading',
    loader = loader,
    loader_type = loader_type,
    loader_args = loader_args,
    finalizer = (finalizer_type == 'fn' and finalizer) or assets._finalizers[finalizer],
    finalizer_args = finalizer_args
  }
  assets._result_cache[id] = entry

  local job = {
    'asset',
    id = id,
    path = path,
    loader = loader,
    loader_type = loader_type,
    loader_args = loader_args
  }
  if assets._lock then
    table.insert(assets._job_queue, job)
  else
    assets.job_channel:push(job)
  end
end

function assets.add(id, data)
  local entry = {
    id = id,
    status = 'loaded',
    result = data
  }
  assets._result_cache[id] = entry
end

function assets.remove(id, destructor)
  local entry = assets._result_cache[id]
  if entry and entry.result then
    assets._result_cache[id] = nil
    return entry.result
  end
end

function assets.clear(destructor)
  assets.job_channel:clear()
  assets._result_cache = {}
end

function assets.status(id)
  local entry = assets._result_cache[id]
  if entry then
    return entry.status, entry.err
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

function assets.loader(id, fn)
  local dump = string.dump(fn)
  local job = {'loader', id = id, fn = dump}
  if assets._lock then
    table.insert(assets._job_queue, job)
  else
    assets._lock = true
    assets.lock_channel:push(assets.num_workers)
    for _ = 1, assets.num_workers do
      assets.job_channel:push(job)
    end
  end
end

function assets.finalizer(id, fn)
  assets._finalizers[id] = fn
end

function assets.require(path, name, initializer)
  if type(name) == 'function' then
    initializer = name
    name = nil
  end
  if initializer then
    initializer = string.dump(initializer)
  end
  local job = {'lib', path = path, name = name, initializer = initializer}
  if assets._lock then
    table.insert(assets._job_queue, job)
  else
    assets._lock = true
    assets.lock_channel:push(assets.num_workers)
    for _ = 1, assets.num_workers do
      assets.job_channel:push(job)
    end
  end
end

function assets.update()
  while assets.result_channel:getCount() > 0 do
    local result = assets.result_channel:pop()
    if result[1] == 'asset' then
      local asset = assets._result_cache[result.id]
      if result.err then
        asset.status = 'error'
        asset.err = result.err
        if assets.onError then
          assets.onError(asset.id, result.err)
        end
      elseif result.data then
        if asset.finalizer then
          asset.result = asset.finalizer(result.data, unpack(asset.finalizer_args))
        else
          asset.result = result.data
        end
        asset.status = 'loaded'
      end
    elseif result[1] == 'lib' then
      if result.status == 'done' then
        assets._lock = false
        assets._nextJob()
      elseif result.status == 'error' then
        if assets.onError then
          assets.onError(result.path, result.err)
        end
      end
    elseif result[1] == 'loader' then
      if result.status == 'done' then
        assets._lock = false
        assets._nextJob()
      elseif result.status == 'error' then
        if assets.onError then
          assets.onError(result.id, result.err)
        end
      end
    end
  end
end

function assets.shutdownWorkers()
  -- Remove any existing jobs and send shutdown signal to all workers
  assets.job_channel:clear()
  for _ = 1, assets.num_workers do
    assets.job_channel:push(-1)
  end
  -- Unlock any threads that might be loading a loader or library
  assets.lock_channel:push(1000000)

  -- Wait for all workers to exit
  for _, worker in ipairs(assets._workers) do
    worker:wait()
  end
end

-- Constants

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

local function threadFn(...)
  require 'love.audio'
  require 'love.image'
  require 'love.sound'
  require 'love.video'
  local thread_id, job_ch, result_ch, lock_ch = ...
  local loaders = {}

  while true do
    local job = job_ch:demand()
    if job == -1 then
      -- Shutdown thread
      return
    elseif job[1] == 'loader' then
      -- Add loader
      local fn, err = loadstring(job.fn)
      if fn then
        loaders[job.id] = fn
      else
        result_ch:push({'loader', thread_id = thread_id, id = job.id, status = 'error', err = err})
      end

      -- Sync up with other threads
      local counter = lock_ch:demand()
      counter = counter - 1
      if counter <= 0 then
        result_ch:push({'loader', thread_id = thread_id, id = job.id, status = 'done'})
      else
        lock_ch:push(counter)
      end
    elseif job[1] == 'lib' then
      -- Add library
      local succ, lib = pcall(require, job.path)
      local result = nil
      if succ then
        if job.initializer then
          local initializer, err = loadstring(job.initializer)
          if initializer then
            local suc, initLib = pcall(initializer, lib)
            if suc then
              if job.name then
                _G[job.name] = initLib
              end
            else
              result = {
                'lib',
                thread_id = thread_id,
                path = job.path,
                status = 'error',
                err = initLib
              }
            end
          else
            result = {'lib', thread_id = thread_id, path = job.path, status = 'error', err = err}
          end
        else
          if job.name then
            _G[job.name] = lib
          end
        end
      else
        result = {'lib', thread_id = thread_id, path = job.path, status = 'error', err = lib}
      end

      if result then
        result_ch:push(result)
      end

      -- Sync up with other threads
      local counter = lock_ch:demand()
      counter = counter - 1
      if counter <= 0 then
        result_ch:push({'lib', thread_id = thread_id, path = job.path, status = 'done'})
      else
        lock_ch:push(counter)
      end
    else
      -- Load asset
      local result
      if job.loader_type == 'str' then
        local succ, data = pcall(loaders[job.loader], job.path, unpack(job.loader_args))
        if succ then
          result = {'asset', thread_id = thread_id, id = job.id, data = data}
        else
          result = {'asset', thread_id = thread_id, id = job.id, err = data}
        end
      elseif job.loader_type == 'fn' then
        local fn, err = loadstring(job.loader)
        if fn then
          local succ, data = pcall(loaders[job.loader], job.path, unpack(job.loader_args))
          if succ then
            result = {'asset', thread_id = thread_id, id = job.id, data = data}
          else
            result = {'asset', thread_id = thread_id, id = job.id, err = data}
          end
        else
          result = {'asset', thread_id = thread_id, id = job.id, err = err}
        end
      end

      result_ch:push(result)
    end
  end
end

assets.WORKER_DUMP = string.dump(threadFn)

-----------------------------
-- Private Interface
-----------------------------

-- Helpers

function assets._createWorker(id)
  local worker_thread =
    love.thread.newThread(love.filesystem.newFileData(assets.WORKER_DUMP, 'assets-thread.lua'))
  worker_thread:start(id, assets.job_channel, assets.result_channel, assets.lock_channel)
  return worker_thread
end

function assets._extractLoader(f)
  local args = {}
  if type(f) == 'table' then
    args = {select(2, unpack(f))}
    f = f[1]
  end

  if type(f) == 'function' then
    return string.dump(f), 'fn', args
  elseif type(f) == 'string' then
    return f, 'str', args
  end
end

function assets._extractFinalizer(f)
  local args = {}
  if type(f) == 'table' then
    args = {select(2, unpack(f))}
    f = f[1]
  end

  if type(f) == 'function' then
    return f, 'fn', args
  elseif type(f) == 'string' then
    return f, 'str', args
  end
end

function assets._nextJob()
  while #assets._job_queue > 0 do
    local job = table.remove(assets._job_queue, 1)
    if job[1] == 'loader' then
      assets._lock = true
      assets.lock_channel:push(assets.num_workers)
      for _ = 1, assets.num_workers do
        assets.job_channel:push(job)
      end
      return
    elseif job[1] == 'lib' then
      assets._lock = true
      assets.lock_channel:push(assets.num_workers)
      for _ = 1, assets.num_workers do
        assets.job_channel:push(job)
      end
      return
    elseif job[1] == 'asset' then
      assets.job_channel:push(job)
    end
  end
end

-- Built-in Loaders

assets._loaders = {}

assets._loaders.data = function(path)
  return love.filesystem.newFileData(path)
end
assets._loaders.default = assets._loaders.data

assets._loaders.audio = function(path, ...)
  return love.audio.newSource(path, ...)
end
assets._loaders.source = assets._loaders.audio

for _, format in ipairs(assets.SUPPORTED_AUDIO_FORMATS) do
  assets._loaders[format] = assets._loaders.audio
end

assets._loaders.soundData = function(path)
  return love.sound.newSoundData(path)
end

assets._loaders.decoder = function(path, ...)
  return love.sound.newDecoder(path, ...)
end

assets._loaders.image = function(path)
  if love.image.isCompressed(path) then
    return love.image.newCompressedData(path)
  else
    return love.image.newImageData(path)
  end
end

for _, format in ipairs(assets.SUPPORTED_IMAGE_FORMATS) do
  assets._loaders[format] = assets._loaders.image
end

assets._loaders.font = assets._loaders.data
assets._loaders.ttf = assets._loaders.font

assets._loaders.imageFont = function(path)
  return love.image.newImageData(path)
end

assets._loaders.video = function(path)
  return love.video.newVideoStream(path)
end
assets._loaders.ogv = assets._loaders.video
assets._loaders.videoStream = assets._loaders.video

-- Built-in finalizers

assets._finalizers = {}

-- Default finalizer, just returns FileData/ImageData/SoundData
assets._finalizers.data = function(data)
  return data
end
assets._finalizers.default = assets._finalizers.data

assets._finalizers.image = function(data, ...)
  return love.graphics.newImage(data, ...)
end

for _, format in ipairs(assets.SUPPORTED_IMAGE_FORMATS) do
  assets._finalizers[format] = assets._finalizers.image
end

assets._finalizers.audio = assets._finalizers.data

for _, format in ipairs(assets.SUPPORTED_AUDIO_FORMATS) do
  assets._finalizers[format] = assets._finalizers.audio
end

assets._finalizers.imagefont = function(data, ...)
  return love.graphics.newImageFont(data, ...)
end

assets._finalizers.font = function(data, ...)
  return love.graphics.newFont(data, ...)
end
assets._finalizers.ttf = assets._finalizers.font

assets._finalizers.video = function(data, ...)
  return love.graphics.newVideo(data, ...)
end
assets._finalizers.ogv = assets._finalizers.video

setmetatable(
  assets,
  {
    __call = function(_, ...)
      return assets.load(...)
    end
  }
)

return assets
