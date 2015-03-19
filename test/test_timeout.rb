require 'test/unit'
require 'event_core'

class TestTimeout < Test::Unit::TestCase

  def setup
    @loop = EventCore::EventLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_1timeout
    got_timeout = false
    @loop.add_timeout(0.1) { got_timeout = true }
    sleep 0.2
    @loop.step
    assert_equal true, got_timeout
  end

  def test_1timeout_repeat
    ntimeouts = 0
    @loop.add_timeout(0.05) { ntimeouts += 1 }
    @loop.add_timeout(0.21) { @loop.quit }
    @loop.run
    assert 4 <= ntimeouts
  end

  def test_1timeout_once
    ntimeouts = 0
    @loop.add_timeout(0.05) { ntimeouts += 1; next false }
    @loop.add_timeout(0.21) { @loop.quit }
    @loop.run
    assert_equal 1, ntimeouts
  end

end