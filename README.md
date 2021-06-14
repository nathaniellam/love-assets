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
  if assets.status('cool-sprite') == 'ready' then
    local sprite = assets.get('cool-sprite')
    love.graphics.draw(sprite, 0, 0)
  end
end
```

# API

## assets.init(opts)

Initializes the library. It should only be called once, typically in `love.load()`.

### Parameters

- opts (table/number) Default = `{num_workers = 1}` Intialization options. When it is a number, it is equivalent to `{num_workers = opts}`.
  - opts.num_workers (number) Default = `1` Number of worker threads to create.
  - opts.onCancel (function) The function that receives loaded data for canceled assets. Signature is `function(id, data)` where id is the asset's id and data is the output of the asset's loader function.

## assets.add(id, data, loader, initializer)

If data is a string then, asynchronously load a resource at the given path, else add an existing asset. Subsequent calls to this function with the same id will override the asset. Loader and initializer are ignored when data is not a path.

### Parameters

- id (any) **Required** The id used to track the resource.
- data (string/any) **Required** The path to the resource or the resource itself.
- loader (string/function/table) The name of the loader, the loader function itself or a table where the first entry is a string/function and the rest are extra args to the loader. Loader will be inferred by file extension if missing. If using a function, it cannot contain upvalues.
- initializer (string/function/table) The name of the initializer, the initalizer function itself or a table where the first entry is a string/function and the rest are extra args to the initializer. Initializer will be inferred by file extension if missing.

## assets.remove(id, destructor)

Removes a resource from the assets cache.

### Parameters

- id (any) **Required** The id used to load the resource.

### Outputs

1. The resource that was removed if it was ready.

## assets.clear()

Clears the entire assets cache.

## assets.get(id)

Retrieves the resource. If the resource does not exist, a second output is returned stating why.

### Parameters

- id (any) **Required** The id used to add the resource.

### Outputs

1. The resource if ready, otherwise `nil`.
2. The reason the resource was not returned, if the resource was `nil`.

## assets.has(id)

Determines if an id has been added.

### Parameters

- id (any) **Required** The id used to add the resource.

### Outputs

1. True if the resource was added, false otherwise

## assets.status(id)

Gets the status of the resource.

### Parameters

- id (any) **Required** The id used to load the resource.

### Outputs

1. The status of the resource which can be one of the following: `ready`, `not found`, `error`, `canceled` and `loading`.
2. The error message if the status is `error`, otherwise `nil`.

## assets.update()

Updates the internals of the library. It should be called every frame, typically in `love.update(dt)`.

## assets.loader(loader_id, loader_fn)

Adds a custom loader that can be used for loading resources. When using a custom library, if the library emits a global or you gave it a name, this will be accessible using _G inside the `loader_fn`. The function runs in the worker threads.

NOTE: Do not use upvalues inside of `loader_fn`.

### Parameters

- loader_id (any) **Required** The id to refer to this loader.
- Loader_fn (function) **Required** The function that will be executed when this loader is used. It has the following signature: `function(path, ...)`. `path` is the path to the resource. `...` are any extra parameters provided at add.

## assets.initializer(initializer_id, initializer_fn)

Adds a custom initializer that can be used for initializing resources. This is run in the main thread.

NOTE: Upvalues are allowed in `initializer_fn`.

### Parameters

- initializer_id (any) **Required** The id to refer to this initializer.
- initializer_fn (function) **Required** The function that will be executed when this initializer is used. It has the following signature: `function(data, ...)`. `data` is the loaded data for the resource. `...` are any extra parameters provided at add.

## assets.require(path, name, initializer)

Adds a custom library that can be used for loading resources.

NOTE: Do not use upvalues inside of `initializer`.

### Parameters

- path (any) **Required** The path to the library.
- name (string) The name of the library which loader functions can reference.
- initializer (function) The function that will be executed when this loader is used. It has the following signature: `function(lib)`. `lib` is the return value of the resource. If a name is also specified, the initializer should return the value that will be assigned to that name in the global namespace for the worker threads. This initializer is different than the ones defined by `assets.initializer()`.

## assets.shutdownWorkers()

Stops all worker threads. It should be called when game is being closed. Some threads may not exit quickly if they are in the middle of loading an asset.

## assets.iter()

Iterates through all assets. Can be used in `for` loops. Each iteration returns the `id`, `status` and `asset`. `asset` is the resource after it is ready, otherwise `nil`.

```lua
for id, status, asset in assets.iter() do
  -- Do something with id, status and asset
end

```

# Loader vs Initializer

A loader is a function that runs in a worker thread. This means it cannot have upvalues when defined in the main thread. It also only has access to the worker thread environment. You must require libraries using `assets.require(...)` in order for them to be accessible to a loader. Loaders only receive the path to an asset plus any extra user args.

An initializer is a function that runs in the main thread. This is usually for using functions that cannot be run in the worker threads. This means that these functions can have access to any upvalues since they will be run in the same environment they are defined in. If you want to add an asset without it going to a background worker, you should just prepare it outside and add it after it is ready.

# Credits

The following test assets were created by [Kenney](https://kenney.nl):

- `Kenney Future.ttf`
- `pixel_style1.png`
- `you_win.ogg`
