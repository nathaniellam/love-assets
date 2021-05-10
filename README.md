# love-assets

This is a library for simplifying asset management in [LÖVE](https://love2d.org) projects.

The main feature is asynchronous loading using threads. When you load a resource, it gets sent to a worker thread to read the data and create the desired object which is then sent back to the main thread.

This library is still a work-in-progress so expect some bugs. It has only been tested against the latest version of LÖVE: `11.3`.

# Features

- Asynchronous/synchronous loading
- Built-in support for most resource types that LÖVE provides
- Custom asset loading

# Installation

Just copy `assets.lua` into your project and load using something like
```lua
local assets = require 'assets'
```

Be sure to call `assets.init(opts)` in `love.load()` and  `assets.update` in `love.update(dt)` somewhere.

# Example

```lua
local assets = require 'assets'

function love.load()
  assets.init() -- Make sure you initialize before using
  assets.load('cool-sprite', 'path/to/sprite.png')
end

function love.update(dt)
  assets.update() -- Make sure you update every frame
end

function love.draw()
  if assets.status('cool-sprite') == 'loaded' then
    local sprite = assets.get('cool-sprite')
    love.graphics.draw(sprite, 0, 0)
  end
end
```

# API

## assets.init(opts)

Initializes the library. It should only be called once.

### Parameters

- opts (table/number) Default = `{num_workers = 1}` Intialization options. When it is a number, it is equivalent to `{num_workers = opts}`.
  - opts.num_workers (number) Default = `1` Number of worker threads to create.
  - opts.job_channel_name (string) Default = `'assets_jobs'` The name of the Channel used to send jobs to workers.
  - opts.result_channel_name (string) Default = `'assets_results'` The name of the Channel used to receive results from workers.

## assets.load(id, path, loader, ...)

Asynchronously load a resource at the given path. Subsequent calls to this function with the same id will do nothing until the asset with that id has been unloaded.

### Parameters

- id (any) **Required** The id used to track the resource.
- path (string) **Required** The path to the resource.
- loader (string/function) The name of the loader or the loader function itself.
- ... (any) Extra args that get passed to the loader function.

## assets.loadSync(id, path, loader, ...)

Synchronously load a resource. Parameters are the same as `assets.load()`.

## assets.remove(id)

Removes a resource from the assets cache.

### Parameters

- id (any) **Required** The id used to load the resource.

### Outputs

1. The resource that was removed.

## assets.clear()

Clears the entire assets cache.

## assets.get(id)

Retrieves the resource. If the resource does not exist, a second output is returned stating why.

### Parameters

- id (any) **Required** The id used to load the resource.

### Outputs

1. The resource if loaded, otherwise `nil`.
2. The reason the resource was not returned, if the resource was `nil`.

## assets.status(id)

Gets the status of the resource.

### Parameters

- id (any) **Required** The id used to load the resource.

### Outputs

1. The status of the resource which can be one of the following: `loaded`, `not found`, `error`, and `loading`.

## assets.update()

Updates the internals of the library. It should be called every frame.

## assets.register(loader_id, loader_fn)

Adds a custom loader that can be used for loading resources.

### Parameters

- loader_id (any) **Required** The id that will be used in `assets.load()`/`assets.loadSync` to use this loader.
- Loader_fn (function) **Required** The function that will be executed when this loader is used. It has the following signature: `function(path, data, ...)`. `path` is the path given. `data` is the data loaded by the worker thread (can be `nil`). `...` are any extra parameters provided at load.

## assets.unregister(loader_id)

Removes a custom loader by id.

### Outputs

1. The function that was removed.

## assets.shutdownWorkers()

Stops all worker threads. It should be called when game is being closed.

# Limitations

Due to how threads work in LÖVE, loaders always run in the main thread and receive the data that was loaded in the thread. This means you should be careful what you put in the loader since it will be running on the main thread, not a worker thread.

# Credits

The following test assets were created by [Kenney](https://kenney.nl):

- `Kenney Future.ttf`
- `pixel_style1.png`
- `you_win.ogg`
