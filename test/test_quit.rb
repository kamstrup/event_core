require 'test/unit'
require 'event_core'

class TestQuit < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
  end

  def teardown
    @loop = nil
  end

  def test_1quit
    did_run = false
    @loop.add_quit { did_run = true }
    @loop.add_once(0.1) { @loop.quit }
    @loop.run
    assert_equal true, did_run
  end

  def test_nquit
    nruns = 0
    (1..10).each { @loop.add_quit { nruns += 1 } }
    @loop.add_once(0.1) { @loop.quit }
    @loop.run
    assert_equal 10, nruns
  end

end