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

assets.JOB_CHANNEL_PREFIX = 'assets_jobs_'
assets.JOB_CHANNEL_PREFIX = 'assets_results_'
assets.CONTROL_CHANNEL_NAME = 'assets'
assets.CHUNK_SIZE = 1048576 -- 1 MB in bytes
assets._background_thread_source =
  [[
  require 'love.video'
  local ctrl_ch_name, chunk_size = ...

  local function getExtension(path)
    local temp = love.filesystem.newFileData("", path)
    local ext = temp:getExtension()
    temp:release()
    return ext
  end

  local control_ch = love.thread.getChannel(ctrl_ch_name)
  local work_ch = control_ch:demand()
  local progress_ch = control_ch:demand()
  while true do
    local job = work_ch:demand()
    if job == -1 then
      -- Received exit command
      return
    else
      local file = love.filesystem.newFile(job.path)
      local ext = getExtension(job.path)
      if ext == 'ogv' then
        local videostream = love.video.newVideoStream(file, unpack(job.args))
        work_ch:supply(videostream)
      else
        local success, err = file:open('r')
        if err then
          work_ch:supply(err)
        else
          local total_bytes = file:getSize()
          local remaining_bytes = total_bytes
          local contents = ''
          while remaining_bytes > 0 do
            -- Check if shutdown has been initiated
            local next = work_ch:peek()
            if next == -1 then
              return
            end
            local read_bytes, num_read = file:read(chunk_size)
            contents = contents .. read_bytes
            remaining_bytes = remaining_bytes - num_read
            progress_ch:push(remaining_bytes / total_bytes)
          end
          file:close()
          local data = love.filesystem.newFileData(contents, job.path)
          work_ch:supply(data)
        end
      end
    end
  end
]]

assets._loaders = {}

-- Default loader, just returns FileData
assets._loaders.data = function(_path, data)
  return data
end

local function generic_image_loader(_path, data, ...)
  return love.graphics.newImage(data, ...)
end
assets._loaders.image = generic_image_loader

local SUPPORTED_IMAGE_FORMATS = {'jpg', 'png', 'bmp'}
for _, format in ipairs(SUPPORTED_IMAGE_FORMATS) do
  assets._loaders[format] = generic_image_loader
end

local function generic_audio_loader(path, data, ...)
  return love.audio.newSource(data or path, ...)
end
assets._loaders.audio = generic_audio_loader

local SUPPORTED_AUDIO_FORMATS = {
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
for _, format in ipairs(SUPPORTED_AUDIO_FORMATS) do
  assets._loaders[format] = generic_audio_loader
end

assets._loaders.imagefont = function(_path, data, ...)
  local image_data = love.image.newImageData(data)
  return love.graphics.newImageFont(image_data, ...)
end

assets._loaders.ttf = function(_path, data, ...)
  return love.graphics.newFont(data, ...)
end

assets._loaders.ogv = function(path, data, ...)
  return love.graphics.newVideo(data or path, ...)
end

-----------------------------
-- Public Interface
-----------------------------

function assets:load(id, path, loader, ...)
  if not self._result_cache[id] then
    local job = {id = id, path = path, args = {...}, loader = loader}
    -- self.job_channel:push(job)

    -- Start loading asset immediately if available worker
    for i = 1, self.num_workers do
      local worker = self._workers[i]
      if worker.status == 'free' then
        self:_start_job(worker, job)
        return
      end
    end

    table.insert(self._job_queue, job)
  end
end

function assets:unload(id)
  if self._result_cache[id] then
    self._result_cache[id] = nil
  end
end

function assets:status(id)
  if self._result_cache[id] then
    return self._result_cache[id].status, self._result_cache[id].progress
  end

  return 'unloaded', nil
end

function assets:get(id)
  local entry = self._result_cache[id]
  if entry then
    if entry.status == 'loaded' then
      return true, entry.result
    else
      return false, entry.err or 'Asset could not be loaded'
    end
  end

  return false, 'Asset not found'
end

function assets:update(dt)
  for i = 1, self.num_workers do
    local worker = self._workers[i]
    if worker.status == 'busy' then
      local data = worker.work_channel:pop()
      if data then
        local job = worker.cur_job
        if type(data) == 'string' then
          job.status = 'error'
          job.err = data
        else
          local loader = job.loader or data:getExtension()
          if type(loader) ~= 'function' then
            loader = self._loaders[loader] or self._loaders.data
          end
          job.result = loader(data, unpack(job.args or {}))
          job.status = 'loaded'
        end

        worker.cur_job = nil
        if #self._job_queue > 0 then
          local id, path = unpack(table.remove(self._job_queue))
          self:_start_job(worker, id, path)
        else
          worker.status = 'free'
        end
      else
        local current_progress = worker.cur_job.progress or 0
        while worker.progress_channel:getCount() > 0 do
          current_progress = worker.progress_channel:pop()
        end
        worker.cur_job.progress = current_progress
      end
    elseif worker.status == 'free' then
      if #self._job_queue > 0 then
        local job = table.remove(self._job_queue)
        self:_start_job(worker, job.id, job.path, job.args, job.loader)
      end
    end
  end
end

function assets:shutdown()
  for _, worker in ipairs(self._workers) do
    worker.work_channel:push(-1)
  end

  for _, worker in ipairs(self._workers) do
    worker.thread:wait()
  end
end

-----------------------------
-- Private Interface
-----------------------------

local instance_num = 1

function assets:_init(opts)
  local instance =
    setmetatable(
    {
      _result_cache = {},
      _workers = {},
      _job_queue = {}
    },
    {__index = self}
  )

  instance.job_channel_name = instance.JOB_CHANNEL_PREFIX .. instance_num
  instance.job_channel = love.thread.getChannel(instance.job_channel_name)
  instance.num_workers = opts.num_workers or 1
  for i = 1, instance.num_workers do
    instance._workers[i] = instance:_create_worker(control_ch)
  end

  return instance
end

function assets:_create_worker(control_ch)
  control_ch = control_ch or love.thread.getChannel(self.CONTROL_CHANNEL_NAME)
  local worker = {status = 'free'}
  worker.thread = love.thread.newThread(self._background_thread_source)
  worker.thread:start(self.CONTROL_CHANNEL_NAME, self.CHUNK_SIZE)
  local work_ch = love.thread.newChannel()
  local progress_ch = love.thread.newChannel()
  control_ch:supply(work_ch)
  control_ch:supply(progress_ch)
  worker.work_channel = work_ch
  worker.progress_channel = progress_ch
  return worker
end

function assets:_start_job(worker, job)
  worker.status = 'busy'
  worker.cur_job = job
  worker.work_channel:supply({path = job.path, args = job.args})
  job.status = 'loading'
  self._result_cache[job.id] = job
end

setmetatable(
  assets,
  {
    __call = function(t, opts)
      return t:_init(opts)
    end
  }
)

return assets
