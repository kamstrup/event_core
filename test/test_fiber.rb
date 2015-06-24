require 'thread'
require 'fiber'
require 'test/unit'
require 'event_core'

class TestThread < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_fiber1
    count = 0
    @loop.add_fiber {
      count += 2
      Fiber.yield
      count += 3
      Fiber.yield
      count += 5
      @loop.add_once { @loop.quit }
    }

    @loop.run

    assert_equal 10, count
  end

  def test_fiber_subtask
    count = 0
    @loop.add_fiber {
      count += 2
      Fiber.yield
      count += Fiber.yield lambda {|task| task.done(3)}
      Fiber.yield
      count += 5
      @loop.add_once { @loop.quit }
    }

    @loop.run

    assert_equal 10, count
  end

  def test_fiber_subtask_slow
    timer_count = 0
    fiber_count = 0

    @loop.add_timeout(0.1) { timer_count += 1 }

    @loop.add_fiber {
      fiber_count += 2
      Fiber.yield
      fiber_count += Fiber.yield lambda { |task|
                             Thread.new { puts "SLEEPING"; sleep 3; puts "SLEPT"; task.done(11) }
                           }
      Fiber.yield
      fiber_count += 5
      @loop.add_once { @loop.quit }
    }

    @loop.run

    assert_equal 18, fiber_count
    assert(timer_count > 20)
  end

end