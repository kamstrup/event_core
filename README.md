EventCore - General Purpose Main Loop for Ruby
----------------------------------------------

Provides the core of a fully asynchronous application. Not intended for super high load or real time environments,
but modeled for simplicity and robustness. Reservations aside, EventCore should still easily provide low enough
latency and high enough throughput for most applications.

Features:
 - Timeouts.
 - Fire-once events.
 - Fire-repeatedly events.
 - Thread safety.
 - Simple idiom for integrating with external threads.
 - Unix signals dispatched on the main loop to avoid the dreaded "trap context".
 - Core is parked in a ```select()``` when the loop is idle to incur negligible load on the system.
 - Async process controls - aka Process.spawn() with callbacks on the main loop thread and automatic reaping of children.

EventCore is heavily inspired by the proven architecture of the GLib main loop from the GNOME project.
Familiarity with that API should not be required though, the EventCore API is small an easy to learn.

Examples
--------

Do something every 200ms for 3s then Quit
=========================================
```rb
require 'event_core'
loop = EventCore::MainLoop.new
loop.add_timeout(0.2) { puts 'Something' }
loop.add_once(3.0) { loop.quit }
loop.run
puts 'Done'
```


Concepts and Architecture
-------------------------
TODO

Caveats & Known Bugs
--------------------

 - If you use multiple main loops on different threads the reaping of child processes using the async spawn is currently broken
 - Unix signal handlers, for the same signal, between two main loops (in the same process) will clobber each other
 - Unlike GMainLoop does not have a concept of priority. All sources on the main loop have equal priority.

FAQ
---
 - _Can I have several main loops in the same process_
   Yes, but see caeveat above, wrt unix signals and loop.spawn()