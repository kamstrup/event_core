require 'test/unit'
require 'event_core'

class TestOnce < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_1once
    n = 0
    @loop.add_once { n += 1 }
    @loop.add_once(0.2) { @loop.quit }
    @loop.run
    assert_equal 1, n
  end

  def test_2once
    n = 0
    @loop.add_once { n += 1 }
    @loop.add_timeout(0.2) { @loop.quit }
    @loop.add_timeout(0.1) { @loop.add_once {n += 1} }
    @loop.run
    assert_equal 2, n
  end

end