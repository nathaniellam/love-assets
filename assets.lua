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
  if type(path) == 'string' then
    local temp = love.filesystem.newFileData(path)
    local ext = temp:getExtension()
    temp:release()
    return ext
  end
  return ''
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
  assets._asset_cache = {}
  assets._workers = {}
  assets._pending_job_queue = {}
  assets._lock = nil
  assets._onCancel = opts.onCancel

  assets.job_channel = love.thread.newChannel()
  assets.result_channel = love.thread.newChannel()
  assets.lock_channel = love.thread.newChannel()
  assets.num_workers = opts.num_workers or 1
  for i = 1, assets.num_workers do
    assets._workers[i] = assets._createWorker()
  end

  for k, v in pairs(assets._loaders) do
    assets.loader(k, v)
  end
end

function assets.add(id, path, loader_id, initializer_id)
  local rev = (assets._asset_cache[id] and assets._asset_cache[id].rev or 0) + 1
  if type(path) == 'string' then
    local loader, loader_type, loader_args = assets._extractLoader(loader_id or getExtension(path))
    local initializer, initializer_args =
      assets._extractInitializer(initializer_id or getExtension(path))
    local asset = {
      id = id,
      rev = rev,
      path = path,
      status = 'loading',
      loader = loader,
      loader_type = loader_type,
      loader_args = loader_args,
      initializer = initializer,
      initializer_args = initializer_args
    }
    assets._asset_cache[id] = asset

    local job = {
      'asset',
      id = id,
      rev = rev,
      path = path,
      loader = loader,
      loader_type = loader_type,
      loader_args = loader_args
    }
    table.insert(assets._pending_job_queue, job)
  else
    local asset = {
      id = id,
      rev = rev,
      status = 'ready',
      result = path
    }
    assets._asset_cache[id] = asset
  end
end

function assets.remove(id)
  local asset = assets._asset_cache[id]
  if not asset then
    error('Attempted to remove ' .. id .. ' which was not found')
  end
  if asset.status == 'ready' then
    assets._asset_cache[id] = nil
    return asset.result
  elseif asset.status == 'loading' then
    asset.status = 'canceled'
  elseif asset.status == 'error' then
    assets._asset_cache[id] = nil
  end
end

function assets.clear()
  for id, asset in pairs(assets._asset_cache) do
    if asset.status == 'ready' then
      assets._asset_cache[id] = nil
    elseif asset.status == 'loading' then
      asset.status = 'canceled'
    end
  end
  assets._pending_job_queue = {}
end

function assets.status(id)
  local asset = assets._asset_cache[id]
  if asset then
    return asset.status, asset.err
  end

  return 'not found', nil
end

function assets.get(id)
  local asset = assets._asset_cache[id]
  if not asset then
    error('Attempted to get ' .. id .. ' which was not found')
  end
  if asset then
    if asset.status == 'ready' then
      return asset.result
    else
      return nil, 'Asset not ready'
    end
  end

  return nil, 'Asset not found'
end

function assets.has(id)
  local asset = assets._asset_cache[id]
  if asset then
    return true
  end
  return false
end

function assets.loader(id, fn)
  local dump = string.dump(fn)
  local job = {'loader', id = id, fn = dump}
  table.insert(assets._pending_job_queue, job)
end

function assets.require(path, name, initializer)
  if type(name) == 'function' then
    initializer = name
    name = nil
  end
  if initializer then
    initializer = string.dump(initializer)
  end
  local job = {'require', path = path, name = name, initializer = initializer}
  table.insert(assets._pending_job_queue, job)
end

function assets.initializer(id, fn)
  assets._initializers[id] = fn
end

function assets.iter()
  local gen, state, prev = pairs(assets._asset_cache)
  return function()
    local id, asset = gen(state, prev)
    if id ~= nil then
      prev = id
      return id, asset.status, asset.data
    end
  end
end

function assets.update()
  while assets.result_channel:getCount() > 0 do
    local result = assets.result_channel:pop()
    if result[1] == 'asset' then
      local asset = assets._asset_cache[result.id]
      if asset.rev == result.rev then
        if result.err then
          if asset.status == 'canceled' then
            assets._asset_cache[asset.id] = nil
          else
            asset.status = 'error'
            asset.err = result.err
          end
        elseif result.data then
          if asset.status == 'canceled' then
            if assets.onCancel then
              assets.onCancel(result.id, result.data)
            end
            assets._asset_cache[asset.id] = nil
          else
            if asset.initializer then
              asset.result = asset.initializer(result.data, unpack(asset.initializer_args))
            else
              asset.result = result.data
            end
            asset.status = 'ready'
          end
        end
      else
        -- When revision differs we can cancel previous entry
        if assets.onCancel then
          assets.onCancel(result.id, result.data)
        end
        assets._asset_cache[asset.id] = nil
      end
    elseif result[1] == 'require' then
      if result.status == 'done' then
        assets._lock = false
      elseif result.status == 'error' then
        error('assets could not require "' .. result.path .. '" due to:\n' .. result.err)
      end
    elseif result[1] == 'loader' then
      if result.status == 'done' then
        assets._lock = false
      elseif result.status == 'error' then
        error('assets could not setup loader "' .. result.id .. '" due to:\n' .. result.err)
      end
    end
  end

  while #assets._pending_job_queue > 0 do
    local job = table.remove(assets._pending_job_queue, 1)
    if job[1] == 'loader' then
      assets._lock = true
      assets.lock_channel:push(assets.num_workers)
      for _ = 1, assets.num_workers do
        assets.job_channel:push(job)
      end
      break
    elseif job[1] == 'require' then
      assets._lock = true
      assets.lock_channel:push(assets.num_workers)
      for _ = 1, assets.num_workers do
        assets.job_channel:push(job)
      end
      break
    elseif job[1] == 'asset' then
      assets.job_channel:push(job)
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
  assets._pending_job_queue = {}

  -- Wait for all workers to exit
  for _, worker in ipairs(assets._workers) do
    worker:wait()
  end
end

function assets.onCancel(...)
  if assets._onCancel then
    assets._onCancel(...)
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
  local job_ch, result_ch, lock_ch = ...
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
        result_ch:push(
          {
            'loader',
            id = job.id,
            status = 'error',
            err = err
          }
        )
        -- Stop thread due to irrecoverable error
        return
      end

      -- Sync up with other threads
      local counter = lock_ch:demand()
      counter = counter - 1
      if counter <= 0 then
        result_ch:push(
          {
            'loader',
            id = job.id,
            status = 'done'
          }
        )
      else
        lock_ch:push(counter)
      end
    elseif job[1] == 'require' then
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
                'require',
                path = job.path,
                status = 'error',
                err = initLib
              }
            end
          else
            result = {
              'require',
              path = job.path,
              status = 'error',
              err = err
            }
          end
        else
          if job.name then
            _G[job.name] = lib
          end
        end
      else
        result = {
          'require',
          path = job.path,
          status = 'error',
          err = lib
        }
      end

      if result then
        result_ch:push(result)
        if result.status == 'error' then
          -- Stop thread due to irrecoverable error
          return
        end
      end

      -- Sync up with other threads
      local counter = lock_ch:demand()
      counter = counter - 1
      if counter <= 0 then
        result_ch:push(
          {
            'require',
            path = job.path,
            status = 'done'
          }
        )
      else
        lock_ch:push(counter)
      end
    else
      -- Load asset
      local result = {'asset', id = job.id, rev = job.rev}
      if job.loader_type == 'str' then
        local succ, data = pcall(loaders[job.loader], job.path, unpack(job.loader_args))
        if succ then
          result.data = data
        else
          result.err = data
        end
      elseif job.loader_type == 'fn' then
        local fn, err = loadstring(job.loader)
        if fn then
          local succ, data = pcall(loaders[job.loader], job.path, unpack(job.loader_args))
          if succ then
            result.data = data
          else
            result.err = data
          end
        else
          result.err = err
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

function assets._createWorker()
  local worker_thread =
    love.thread.newThread(love.filesystem.newFileData(assets.WORKER_DUMP, 'assets-thread.lua'))
  worker_thread:start(assets.job_channel, assets.result_channel, assets.lock_channel)
  return worker_thread
end

function assets._extractLoader(id)
  local args = {}
  if type(id) == 'table' then
    args = {select(2, unpack(id))}
    id = id[1]
  end

  if type(id) == 'function' then
    return string.dump(id), 'fn', args
  elseif type(id) == 'string' then
    return id, 'str', args
  end
end

function assets._extractInitializer(id)
  local args = {}
  if type(id) == 'table' then
    args = {select(2, unpack(id))}
    id = id[1]
  end

  if type(id) == 'function' then
    return id, args
  elseif type(id) == 'string' then
    return assets._initializers[id], args
  end
end

-- Built-in Loaders

assets._loaders = {}

assets._loaders.data = function(path)
  return love.filesystem.newFileData(path)
end

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

-- Built-in initializers

assets._initializers = {}

-- Default initializer, just returns FileData/ImageData/SoundData
assets._initializers.data = function(data)
  return data
end

assets._initializers.image = function(data, ...)
  return love.graphics.newImage(data, ...)
end

for _, format in ipairs(assets.SUPPORTED_IMAGE_FORMATS) do
  assets._initializers[format] = assets._initializers.image
end

assets._initializers.audio = assets._initializers.data

for _, format in ipairs(assets.SUPPORTED_AUDIO_FORMATS) do
  assets._initializers[format] = assets._initializers.audio
end

assets._initializers.imagefont = function(data, ...)
  return love.graphics.newImageFont(data, ...)
end

assets._initializers.font = function(data, ...)
  return love.graphics.newFont(data, ...)
end
assets._initializers.ttf = assets._initializers.font

assets._initializers.video = function(data, ...)
  return love.graphics.newVideo(data, ...)
end
assets._initializers.ogv = assets._initializers.video

return assets
