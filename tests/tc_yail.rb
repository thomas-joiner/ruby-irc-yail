#!/usr/bin/env ruby
require File.dirname(__FILE__) + "/net_yail"
require File.dirname(__FILE__) + "/mock_irc"
require "test/unit"

# This test suite is built as an attempt to validate basic functionality in YAIL.  Due to the
# threading of the library, things are going to be... weird.  Good luck, me.
class YailSessionTest < Test::Unit::TestCase
  def setup
    @mockirc = MockIRC.new
    @log = Logger.new($stderr)
    @log.level = Logger::WARN
    @yail = Net::YAIL.new(
      :io => @mockirc, :address => "fake-irc.nerdbucket.com", :log => @log,
      :nicknames => ["Bot"], :realname => "Net::YAIL", :username => "Username"
    )
  end

  # Sets up all our handlers the legacy way - allows testing that things work as they used to
  def setup_legacy_handling
    ###
    # Simple counters for basic testing of successful handler registration
    ###

    @msg = Hash.new(0)
    @yail.prepend_handler(:incoming_welcome)        { |text, args|                          @msg[:welcome] += 1 }
    @yail.prepend_handler(:incoming_endofmotd)      { |text, args|                          @msg[:endofmotd] += 1 }
    @yail.prepend_handler(:incoming_notice)         { |f, actor, target, text|              @msg[:notice] += 1 }
    @yail.prepend_handler(:incoming_nick)           { |f, actor, nick|                      @msg[:nick] += 1 }
    @yail.prepend_handler(:incoming_bannedfromchan) { |text, args|                          @msg[:bannedfromchan] += 1 }
    @yail.prepend_handler(:incoming_join)           { |f, actor, target|                    @msg[:join] += 1 }
    @yail.prepend_handler(:incoming_mode)           { |f, actor, target, modes, objects|    @msg[:mode] += 1 }
    @yail.prepend_handler(:incoming_msg)            { |f, actor, target, text|              @msg[:msg] += 1 }
    @yail.prepend_handler(:incoming_act)            { |f, actor, target, text|              @msg[:act] += 1 }
    @yail.prepend_handler(:incoming_ctcp)           { |f, actor, target, text|              @msg[:ctcp] += 1 }
    @yail.prepend_handler(:incoming_ping)           { |text|                                @msg[:ping] += 1 }
    @yail.prepend_handler(:incoming_quit)           { |f, actor, text|                      @msg[:quit] += 1 }
    @yail.prepend_handler(:outgoing_mode)           { |target, modes, objects|              @msg[:o_mode] += 1 }
    @yail.prepend_handler(:outgoing_join)           { |channel, pass|                       @msg[:o_join] += 1 }

    ###
    # More complex handlers to test parsing of messages
    ###

    # Channels list helps us test joins
    @channels = []
    @yail.prepend_handler(:incoming_join) do |fullactor, actor, target|
      @channels.push(target) if @yail.me == actor
    end

    # Gotta store extra info on notices to test event parsing
    @notices = []
    @yail.prepend_handler(:incoming_notice) do |f, actor, target, text|
      @notices.push({:server => f, :nick => actor, :target => target, :text => text})
    end

    @yail.prepend_handler(:incoming_ping) { |text| @ping_message = text }
    @yail.prepend_handler(:incoming_quit) { |f, actor, text| @quit = {:full => f, :nick => actor, :text => text} }
    @yail.prepend_handler(:outgoing_join) {|channel, pass| @out_join = {:channel => channel, :password => pass} }
    @yail.prepend_handler(:incoming_msg) {|f, actor, channel, text| @privmsg = {:channel => channel, :nick => actor, :text => text} }
    @yail.prepend_handler(:incoming_ctcp) {|f, actor, channel, text| @ctcp = {:channel => channel, :nick => actor, :text => text} }
    @yail.prepend_handler(:incoming_act) {|f, actor, channel, text| @act = {:channel => channel, :nick => actor, :text => text} }
  end

  # Waits until the mock IRC reports it has no more output - i.e., we've read everything available
  def wait_for_irc
    while @mockirc.ready?
      sleep 0.05
    end

    # For safety, we need to wait yet again to be sure YAIL has processed the data it read.
    # This is hacky, but it decreases random failures quite a bit
    sleep 0.1
  end

  # Log in to fake server, do stuff, see that basic handling and such are working.  For simplicity,
  # this will be the all-encompassing "everything" test for legacy handling
  def test_legacy
    # Set up legacy handlers
    setup_legacy_handling

    common_tests
  end

  # Resets the messages hash, mocks the IRC server to send string to us, waits for the response, yields to the block
  def mock_message(string)
    @msg = Hash.new(0)
    @mockirc.add_output string
    wait_for_irc
    yield
  end

  # Runs basic tests, verifying that we get expected results from a mocked session.  Handlers set
  # via legacy prepend_handler should be just the same as new handler system.
  def common_tests
    @yail.start_listening

    # Wait until all data has been read and check messages
    wait_for_irc
    assert_equal 1, @msg[:welcome]
    assert_equal 1, @msg[:endofmotd]
    assert_equal 3, @msg[:notice]

    # Intense notice test - make sure all events were properly translated
    assert_equal ['fakeirc.org', nil, 'fakeirc.org'], @notices.collect {|n| n[:server]}
    assert_equal ['', '', ''], @notices.collect {|n| n[:nick]}
    assert_equal ['AUTH', 'AUTH', 'Bot'], @notices.collect {|n| n[:target]}
    assert_match %r|looking up your host|i, @notices.first[:text]
    assert_match %r|looking up your host|i, @notices[1][:text]
    assert_match %r|you are exempt|i, @notices.last[:text]

    # Test magic methods that set up the bot
    assert_equal "Bot", @yail.me, "Should have set @yail.me automatically on welcome handler"
    assert_equal 1, @msg[:o_mode], "Should have auto-sent mode +i"

    # Make sure nick change works
    @yail.nick "Foo"
    wait_for_irc
    assert_equal "Foo", @yail.me, "Should have set @yail.me on explicit nick change"

    # Join a channel where we've been banned
    @yail.join("#banned")
    wait_for_irc
    assert_equal 1, @msg[:bannedfromchan]
    assert_equal "#banned", @out_join[:channel]
    assert_equal "", @out_join[:password]
    assert_equal [], @channels

    # Join some other channel
    @yail.join("#foosball", "pass")
    wait_for_irc
    assert_equal "#foosball", @out_join[:channel]
    assert_equal "pass", @out_join[:password]
    assert_equal ['#foosball'], @channels

    # Mock some chatter to verify PRIVMSG info
    mock_message ":Nerdmaster!nerd@nerdbucket.com PRIVMSG #foosball :#{@yail.me}: Welcome!" do
      assert_equal 1, @msg[:msg]
      assert_equal 0, @msg[:act]
      assert_equal 0, @msg[:ctcp]

      assert_equal "Nerdmaster", @privmsg[:nick]
      assert_equal "#foosball", @privmsg[:channel]
      assert_equal "#{@yail.me}: Welcome!", @privmsg[:text]
    end

    # CTCP
    mock_message ":Nerdmaster!nerd@nerdbucket.com PRIVMSG #foosball :\001CTCP THING\001" do
      assert_equal 0, @msg[:msg]
      assert_equal 0, @msg[:act]
      assert_equal 1, @msg[:ctcp]

      assert_equal "Nerdmaster", @ctcp[:nick]
      assert_equal "#foosball", @ctcp[:channel]
      assert_equal "CTCP THING", @ctcp[:text]
    end

    # ACT
    mock_message ":Nerdmaster!nerd@nerdbucket.com PRIVMSG #foosball :\001ACTION vomits on you\001" do
      assert_equal 0, @msg[:msg]
      assert_equal 1, @msg[:act]
      assert_equal 0, @msg[:ctcp]

      assert_equal "Nerdmaster", @act[:nick]
      assert_equal "#foosball", @act[:channel]
      assert_equal "vomits on you", @act[:text]
    end

    # PING
    mock_message "PING boo" do
      assert_equal 1, @msg[:ping]
      assert_equal 'boo', @ping_message
    end

    # User quits
    mock_message ":Nerdmaster!nerd@nerdbucket.com QUIT :Quit: Bye byes" do
      assert_equal 1, @msg[:quit]
      assert_equal 'Nerdmaster!nerd@nerdbucket.com', @quit[:full]
      assert_equal 'Nerdmaster', @quit[:nick]
      assert_equal 'Quit: Bye byes', @quit[:text]
    end
  end
end
