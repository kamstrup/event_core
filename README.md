EventCore - General Purpose Main Loop for Ruby
==============================================

Provides the core of a fully asynchronous application. Modeled for simplicity and robustness,
less so for super high load or real time environments. Reservations aside, EventCore should
still easily provide low enough latency and high enough throughput for most applications.

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

Do something every 200ms for 3s then quit:

```rb
require 'event_core'
loop = EventCore::MainLoop.new
loop.add_timeout(0.2) { puts 'Something' }
loop.add_once(3.0) { puts 'Quitting'; loop.quit }
loop.run
puts 'Done'
```

Sit idle and print the names of the signals it receives:
```rb
...
loop.add_unix_signal('HUP', 'USR1', 'USR2') { |signals|
  puts "Got signals: #{signals.map { |signo| Signal.signame(signo) } }"

}

puts "Kill me with PID #{Process.pid}, fx 'kill -HUP #{Process.pid}'"
loop.run
puts 'Done'
```

Spin off a child process an check how it goes when it terminates:
```rb
...
loop.spawn("sleep 10") { |status|
  puts "Child process terminated: #{status}"
}
```
(Note - ```loop.spawn``` accepts all the same parameters as convential Ruby ```Process.spawn```)

Do something on the main loop when a long running thread detects there is work to do:
```rb
require 'thread'
...

thr = Thread.new {
  sleep 5 # Working hard! Or hardly working, eh!?
  loop.add_once { puts 'Yay! Back on the main loop' }
  sleep 5
  loop.add_once { puts 'I quit!'; loop.quit }
}

loop.run
puts 'All done'

```



Concepts and Architecture
-------------------------
TODO, mainloop, sources, triggers, idles, timeouts, select io

Caveats & Known Bugs
--------------------

 - If you use multiple main loops on different threads the reaping of child processes using the async spawn is currently broken
 - Unix signal handlers, for the same signal, between two main loops (in the same process) will clobber each other
 - Unlike GMainLoop, EventCore does not have a concept of priority. All sources on the main loop have equal priority.

FAQ
---
 - *Can I have several main loops in the same process*
   Yes, but see caeveat above, wrt unix signals and loop.spawn()