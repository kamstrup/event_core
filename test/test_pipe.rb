require 'test/unit'
require 'event_core'

class TestPipe < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
    @loop.add_once(30) { raise 'Test timed out!' }
  end

  def teardown
    @loop = nil
  end

  def test_simple
    msg = nil
    pipe_source = EventCore::PipeSource.new
    pipe_source.trigger { |buf| msg = buf; @loop.quit }
    pipe_source.write('hello')
    @loop.add_source(pipe_source)
    @loop.add_once(0.4) { @loop.quit }
    @loop.run
    assert_equal 'hello', msg
  end

end