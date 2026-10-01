# data

The city lives here: one JSON file per collection, written by
`adapter/resource_store.lua` through `SaveResourceFile`.

**This folder has to exist before the server starts.** `SaveResourceFile` does
not create directories, and when the folder is missing every write fails with
no reason given, which reads as "could not be written" for every collection at
once. That is what a first boot looked like before this file existed.

The contents are per-server state and are not committed. This file is, so the
folder is.
