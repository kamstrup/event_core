require 'test/unit'
require 'event_core'

class TestQuit < Test::Unit::TestCase

  def setup
    @loop = EventCore::MainLoop.new
    @loop.add_once(5) { raise "Test timed out!" }
    # WAT: If we set @rio, @wio = IO.pipe here,
    # they come up nil in the tests, when run under 'rake test',
    # but work when run with ruby -Ilib -Itest test/test_io.rb
  end

  def teardown
    @loop = nil
    @rio.close unless @rio.closed?
    @wio.close unless @wio.closed?
  end

  def test_small
    @rio, @wio = IO.pipe

    buf = ''
    @loop.add_write(@wio, 'hello') { |exception|
      assert_nil exception
    }
    @loop.add_read(@rio) { |_buf, exception|
      assert_nil exception
      @loop.quit if _buf.nil? # EOF
      buf << _buf unless _buf.nil?
    }
    @loop.run
    assert_equal 'hello', buf
  end

  def test_medium
    @rio, @wio = IO.pipe

    expect = '1234hello'*100
    buf = ''
    @loop.add_write(@wio, expect) { |exception|
      assert_nil exception
    }
    @loop.add_read(@rio) { |_buf, exception|
      assert_nil exception
      @loop.quit if _buf.nil? # EOF
      buf << _buf unless _buf.nil?
    }
    @loop.run
    assert_equal expect, buf
  end

  def test_large_non_ascii
    @rio, @wio = IO.pipe

    expect = "1234hellotherewewritealotofdatathistimearound@^¨1$§åæø\n\t\r"*4097
    buf = ''
    @loop.add_write(@wio, expect) { |exception|
      if exception
        puts "EXCEPTION: #{exception}"
        puts exception.backtrace.join("\n\t")
        assert false
      end
    }
    @loop.add_read(@rio) { |_buf, exception|
      assert_nil exception
      @loop.quit if _buf.nil? # EOF
      buf << _buf unless _buf.nil?
    }
    @loop.add_once(2) { @loop.quit }
    @loop.run

    assert_equal expect.bytesize, buf.bytesize
    assert_equal expect.bytes, buf.bytes
  end

end